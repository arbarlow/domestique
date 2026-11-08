package core

import (
	"fmt"
	"math/rand/v2"
)

// Workspace names: famous climbs and bergs, same list as the Mac app.
var climbs = []string{
	"ventoux", "galibier", "tourmalet", "stelvio", "zoncolan", "mortirolo", "angliru", "alpe", "izoard",
	"madeleine", "aubisque", "gavia", "finestre", "croix-de-fer", "glandon", "telegraphe", "peyresourde",
	"aspin", "joux-plane", "colombiere", "ballon", "planche", "superbagneres", "hautacam", "luz-ardiden",
	"portet", "envalira", "lagos", "bola-del-mundo", "mont-cenis", "iseran", "bonette", "vars", "agnel",
	"sestriere", "pordoi", "giau", "fedaia", "sella", "falzarego", "tre-cime", "grossglockner", "kitzbuhel",
	"mur-de-huy", "koppenberg", "paterberg", "oude-kwaremont", "muur", "kemmelberg", "poggio", "cipressa",
	"turchino", "ghisallo", "sormano", "colle-delle-finestre", "stelvio-north", "cormet", "saisies", "aravis",
	"semnoz", "saleve", "granier", "chartreuse", "vercors", "lautaret", "allos", "cayolle", "turini",
	"madone", "eze", "teide", "puig-major", "sa-calobra", "ventoux-bedoin", "jaizkibel", "arrate",
}

// nextName picks an unused climb, then climb-2, climb-3, ...
func nextName(used map[string]bool) string {
	perm := rand.Perm(len(climbs))
	for _, i := range perm {
		if !used[climbs[i]] {
			return climbs[i]
		}
	}
	for n := 2; ; n++ {
		for _, i := range perm {
			if name := fmt.Sprintf("%s-%d", climbs[i], n); !used[name] {
				return name
			}
		}
	}
}
