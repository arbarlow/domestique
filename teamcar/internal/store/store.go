// Package store persists Team Car state in one SQLite file (WAL mode).
//
// Entities are protobuf blobs keyed by id, so the schema evolves with radio.proto. Transcripts are
// one row per item with a per-rider monotonic seq: rewriting an item gives it a new seq, so
// "everything after seq N" is always the set of items a client is missing.
package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite"

	radiov1 "github.com/arbarlow/domestique/teamcar/gen/radio/v1"
)

var ErrNotFound = errors.New("not found")

type Store struct {
	db *sql.DB
	mu sync.Mutex // serialises seq allocation per rider
}

func Open(path string) (*Store, error) {
	dsn := "file:" + path + "?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(ON)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// One writer connection keeps SQLite simple; reads are fast enough on the same connection.
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	_, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS repositories (id TEXT PRIMARY KEY, data BLOB NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS workspaces (id TEXT PRIMARY KEY, repository_id TEXT NOT NULL, data BLOB NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS riders (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, data BLOB NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS transcript (
  rider_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  pos INTEGER NOT NULL,
  data BLOB NOT NULL,
  PRIMARY KEY (rider_id, item_id)
);
CREATE INDEX IF NOT EXISTS transcript_seq ON transcript (rider_id, seq);
CREATE TABLE IF NOT EXISTS tokens (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  scope INTEGER NOT NULL,
  hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL DEFAULT 0
);
`)
	return err
}

// ---- meta

func (s *Store) Meta(key string) (string, error) {
	var v string
	err := s.db.QueryRow(`SELECT value FROM meta WHERE key = ?`, key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return v, err
}

func (s *Store) SetMeta(key, value string) error {
	_, err := s.db.Exec(`INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value)
	return err
}

// ---- generic entity helpers

func now() int64 { return time.Now().UnixMilli() }

func loadAll[T proto.Message](db *sql.DB, query string, newT func() T, args ...any) ([]T, error) {
	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []T
	for rows.Next() {
		var b []byte
		if err := rows.Scan(&b); err != nil {
			return nil, err
		}
		m := newT()
		if err := proto.Unmarshal(b, m); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// ---- repositories

func (s *Store) Repositories() ([]*radiov1.Repository, error) {
	return loadAll(s.db, `SELECT data FROM repositories ORDER BY rowid`, func() *radiov1.Repository { return &radiov1.Repository{} })
}

func (s *Store) PutRepository(r *radiov1.Repository) error {
	b, err := proto.Marshal(r)
	if err != nil {
		return err
	}
	_, err = s.db.Exec(`INSERT INTO repositories (id, data, updated_at) VALUES (?, ?, ?)
ON CONFLICT(id) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at`, r.Id, b, now())
	return err
}

func (s *Store) DeleteRepository(id string) error {
	_, err := s.db.Exec(`DELETE FROM repositories WHERE id = ?`, id)
	return err
}

// ---- workspaces

func (s *Store) Workspaces() ([]*radiov1.Workspace, error) {
	return loadAll(s.db, `SELECT data FROM workspaces ORDER BY rowid`, func() *radiov1.Workspace { return &radiov1.Workspace{} })
}

func (s *Store) PutWorkspace(w *radiov1.Workspace) error {
	b, err := proto.Marshal(w)
	if err != nil {
		return err
	}
	_, err = s.db.Exec(`INSERT INTO workspaces (id, repository_id, data, updated_at) VALUES (?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at`, w.Id, w.RepositoryId, b, now())
	return err
}

// DeleteWorkspace deletes a workspace, its riders and their transcripts.
func (s *Store) DeleteWorkspace(id string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM transcript WHERE rider_id IN (SELECT id FROM riders WHERE workspace_id = ?)`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM riders WHERE workspace_id = ?`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM workspaces WHERE id = ?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

// ImportedRider is a rider and its transcript, in display order.
type ImportedRider struct {
	Rider *radiov1.Rider
	Items []*radiov1.TranscriptItem
}

// ImportWorkspace writes a workspace with its riders and transcripts in one transaction. Each
// rider's items get seqs (and so positions) 1..n in the order given. Returns each rider's last seq.
func (s *Store) ImportWorkspace(w *radiov1.Workspace, riders []ImportedRider) ([]uint64, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	b, err := proto.Marshal(w)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(`INSERT INTO workspaces (id, repository_id, data, updated_at) VALUES (?, ?, ?, ?)`, w.Id, w.RepositoryId, b, now()); err != nil {
		return nil, err
	}
	last := make([]uint64, len(riders))
	for i, r := range riders {
		// Clear rows a crash may have orphaned (the caller checked the rider id is unused).
		if _, err := tx.Exec(`DELETE FROM transcript WHERE rider_id = ?`, r.Rider.Id); err != nil {
			return nil, err
		}
		var seq uint64
		for _, it := range r.Items {
			b, err := proto.Marshal(it)
			if err != nil {
				return nil, err
			}
			seq++
			if _, err := tx.Exec(`INSERT INTO transcript (rider_id, item_id, seq, pos, data) VALUES (?, ?, ?, ?, ?)`,
				r.Rider.Id, it.Id, int64(seq), int64(seq), b); err != nil {
				return nil, err
			}
		}
		last[i] = seq
		meta := proto.Clone(r.Rider).(*radiov1.Rider)
		meta.LastSeq = seq
		b, err := proto.Marshal(meta)
		if err != nil {
			return nil, err
		}
		if _, err := tx.Exec(`INSERT INTO riders (id, workspace_id, data, updated_at) VALUES (?, ?, ?, ?)`, meta.Id, meta.WorkspaceId, b, now()); err != nil {
			return nil, err
		}
	}
	return last, tx.Commit()
}

// ---- riders

func (s *Store) Riders() ([]*radiov1.Rider, error) {
	return loadAll(s.db, `SELECT data FROM riders ORDER BY rowid`, func() *radiov1.Rider { return &radiov1.Rider{} })
}

func (s *Store) PutRider(r *radiov1.Rider) error {
	b, err := proto.Marshal(r)
	if err != nil {
		return err
	}
	_, err = s.db.Exec(`INSERT INTO riders (id, workspace_id, data, updated_at) VALUES (?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at`, r.Id, r.WorkspaceId, b, now())
	return err
}

func (s *Store) DeleteRider(id string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM transcript WHERE rider_id = ?`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM riders WHERE id = ?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

// ---- transcript

// LastSeq returns the highest seq persisted for a rider (0 if none).
func (s *Store) LastSeq(riderID string) (uint64, error) {
	var seq sql.NullInt64
	err := s.db.QueryRow(`SELECT MAX(seq) FROM transcript WHERE rider_id = ?`, riderID).Scan(&seq)
	return uint64(seq.Int64), err
}

// PutItems writes items for a rider, assigning consecutive seqs after `after`. Returns the new last
// seq. The caller (the rider goroutine) owns seq allocation for its rider.
func (s *Store) PutItems(riderID string, after uint64, items []*radiov1.TranscriptItem) (uint64, error) {
	if len(items) == 0 {
		return after, nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return after, err
	}
	defer tx.Rollback()
	// pos is the seq of the first write and never changes: display order.
	stmt, err := tx.Prepare(`INSERT INTO transcript (rider_id, item_id, seq, pos, data) VALUES (?, ?, ?, ?, ?)
ON CONFLICT(rider_id, item_id) DO UPDATE SET seq = excluded.seq, data = excluded.data`)
	if err != nil {
		return after, err
	}
	defer stmt.Close()
	seq := after
	for _, it := range items {
		b, err := proto.Marshal(it)
		if err != nil {
			return after, err
		}
		seq++
		if _, err := stmt.Exec(riderID, it.Id, int64(seq), int64(seq), b); err != nil {
			return after, err
		}
	}
	if err := tx.Commit(); err != nil {
		return after, err
	}
	return seq, nil
}

// ItemsAfter returns up to limit items with seq > after, in seq order (for paging).
func (s *Store) ItemsAfter(riderID string, after uint64, limit int) ([]*radiov1.TranscriptEntry, error) {
	return s.items(`SELECT seq, pos, data FROM transcript WHERE rider_id = ? AND seq > ? ORDER BY seq LIMIT ?`, riderID, after, limit)
}

// ItemsAfterInOrder returns every item with seq > after, in display (creation) order (for replay).
func (s *Store) ItemsAfterInOrder(riderID string, after uint64) ([]*radiov1.TranscriptEntry, error) {
	return s.items(`SELECT seq, pos, data FROM transcript WHERE rider_id = ? AND seq > ? ORDER BY pos LIMIT ?`, riderID, after, 0)
}

func (s *Store) items(query, riderID string, after uint64, limit int) ([]*radiov1.TranscriptEntry, error) {
	if limit <= 0 {
		limit = 1 << 30
	}
	rows, err := s.db.Query(query, riderID, int64(after), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*radiov1.TranscriptEntry
	for rows.Next() {
		var seq, pos int64
		var b []byte
		if err := rows.Scan(&seq, &pos, &b); err != nil {
			return nil, err
		}
		it := &radiov1.TranscriptItem{}
		if err := proto.Unmarshal(b, it); err != nil {
			return nil, err
		}
		out = append(out, &radiov1.TranscriptEntry{Seq: uint64(seq), Item: it, Position: uint64(pos)})
	}
	return out, rows.Err()
}

// ---- tokens

// TokenPrefix marks Team Car secrets so they're recognisable in config files and secret scanners.
const TokenPrefix = "tc_"

func hashToken(secret string) string {
	h := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(h[:])
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

// CreateToken stores a new token and returns its info and the secret (shown once).
//
// Secrets are 256 random bits, so a fast hash is enough (no password stretching needed).
func (s *Store) CreateToken(name string, scope radiov1.TokenScope) (*radiov1.TokenInfo, string, error) {
	if scope == radiov1.TokenScope_TOKEN_SCOPE_UNSPECIFIED {
		return nil, "", fmt.Errorf("token scope is required")
	}
	secret := TokenPrefix + randomHex(32)
	info := &radiov1.TokenInfo{Id: "tok_" + randomHex(6), Name: name, Scope: scope, CreatedAtMs: now()}
	_, err := s.db.Exec(`INSERT INTO tokens (id, name, scope, hash, created_at) VALUES (?, ?, ?, ?, ?)`,
		info.Id, name, int32(scope), hashToken(secret), info.CreatedAtMs)
	if err != nil {
		return nil, "", err
	}
	return info, secret, nil
}

// Authenticate returns the token's info, or ErrNotFound.
func (s *Store) Authenticate(secret string) (*radiov1.TokenInfo, error) {
	if !strings.HasPrefix(secret, TokenPrefix) {
		return nil, ErrNotFound
	}
	want := hashToken(secret)
	info := &radiov1.TokenInfo{}
	var scope int32
	var hash string
	err := s.db.QueryRow(`SELECT id, name, scope, hash, created_at, last_used_at FROM tokens WHERE hash = ?`, want).
		Scan(&info.Id, &info.Name, &scope, &hash, &info.CreatedAtMs, &info.LastUsedAtMs)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if subtle.ConstantTimeCompare([]byte(hash), []byte(want)) != 1 {
		return nil, ErrNotFound
	}
	info.Scope = radiov1.TokenScope(scope)
	info.LastUsedAtMs = now()
	_, _ = s.db.Exec(`UPDATE tokens SET last_used_at = ? WHERE id = ?`, info.LastUsedAtMs, info.Id)
	return info, nil
}

func (s *Store) Tokens() ([]*radiov1.TokenInfo, error) {
	rows, err := s.db.Query(`SELECT id, name, scope, created_at, last_used_at FROM tokens ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*radiov1.TokenInfo
	for rows.Next() {
		t := &radiov1.TokenInfo{}
		var scope int32
		if err := rows.Scan(&t.Id, &t.Name, &scope, &t.CreatedAtMs, &t.LastUsedAtMs); err != nil {
			return nil, err
		}
		t.Scope = radiov1.TokenScope(scope)
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Store) RevokeToken(id string) error {
	res, err := s.db.Exec(`DELETE FROM tokens WHERE id = ?`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// ServerID returns this Team Car's stable id, creating it on first use.
func (s *Store) ServerID(ctx context.Context) (string, error) {
	_ = ctx
	id, err := s.Meta("server_id")
	if err != nil || id != "" {
		return id, err
	}
	id = "tc_" + randomHex(8)
	return id, s.SetMeta("server_id", id)
}

// Item returns one transcript item, or nil if it doesn't exist.
func (s *Store) Item(riderID, itemID string) (*radiov1.TranscriptItem, error) {
	var b []byte
	err := s.db.QueryRow(`SELECT data FROM transcript WHERE rider_id = ? AND item_id = ?`, riderID, itemID).Scan(&b)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	it := &radiov1.TranscriptItem{}
	return it, proto.Unmarshal(b, it)
}
