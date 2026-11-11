package contextual

import (
	"cmp"
	"encoding/json"
	"errors"
	"math"
	"math/bits"
	"slices"
	"strconv"
	"strings"
)

// SlotBlock is one block of the rendered page around an ad slot: the
// SimHash of its words and its offset from the slot in viewport heights,
// negative above (already read), positive below (not yet seen).
type SlotBlock struct {
	SimHash uint64
	Offset  float64
}

// Slot is what the Prebid module (sdks/prebid) puts in the bid request,
// ortb2Imp.ext.data.ctx: {"v":1,"vh":844,"b":[["<simhash hex>",<offset>],...]}.
type Slot struct {
	Blocks []SlotBlock
}

var errSlot = errors.New("contextual: malformed ortb2Imp.ext.data.ctx")

// UnmarshalJSON reads ortb2Imp.ext.data.ctx; only b is used.
//
//	{"v":1,"vh":844,"b":[["28b95a9f8d39808e",-0.42]]}
//	// Slot{Blocks: []SlotBlock{{SimHash: 0x28b95a9f8d39808e, Offset: -0.42}}}
func (s *Slot) UnmarshalJSON(b []byte) error {
	var wire struct {
		B [][2]json.RawMessage `json:"b"`
	}
	if err := json.Unmarshal(b, &wire); err != nil {
		return errSlot
	}
	s.Blocks = s.Blocks[:0]
	for _, pair := range wire.B {
		var hash string
		var offset float64
		if json.Unmarshal(pair[0], &hash) != nil || json.Unmarshal(pair[1], &offset) != nil {
			return errSlot
		}
		h, err := strconv.ParseUint(hash, 16, 64)
		if err != nil {
			return errSlot
		}
		s.Blocks = append(s.Blocks, SlotBlock{SimHash: h, Offset: offset})
	}

	return nil
}

// SlotOfGPID fills s with the surroundings of the ad container a GPID names,
// from the crawler's estimated layout: the 12 labelled blocks nearest it
// within 3 viewports. The container id is what follows the GPID's last '#'
// ("/1234/home#div-gpt-ad-top" names "div-gpt-ad-top"), or the whole GPID.
// For bid requests without ext.data.ctx. False when the page has no such
// container.
func (p *Profile) SlotOfGPID(gpid string, s *Slot) bool {
	if i := strings.LastIndexByte(gpid, '#'); i >= 0 {
		gpid = gpid[i+1:]
	}
	at := slices.IndexFunc(p.AdSlots, func(a AdSlot) bool { return a.ID == gpid })
	if at < 0 {
		return false
	}
	y := float64(p.AdSlots[at].Top)
	s.Blocks = s.Blocks[:0]
	for _, b := range p.Blocks {
		if d := float64(b.Top) - y; math.Abs(d) <= 3 {
			s.Blocks = append(s.Blocks, SlotBlock{SimHash: b.SimHash, Offset: d})
		}
	}
	slices.SortStableFunc(s.Blocks, func(a, b SlotBlock) int {
		return cmp.Compare(math.Abs(a.Offset), math.Abs(b.Offset))
	})
	s.Blocks = s.Blocks[:min(len(s.Blocks), 12)]

	return true
}

// Geometry is how far a format's context reaches (src/lib/slot.ml): the
// page's weight against the blocks around the slot, and how fast a block's
// weight decays with distance above and below.
type Geometry struct {
	PageWeight, ReachAbove, ReachBelow float64
}

// GeometryOf mirrors Slot.geometry: priors per format class, to be fitted.
// The classes are fullscreen, scroll-through, in-article, sticky and banner
// (src/lib/slot.ml says which ad formats map to each). Fullscreen and
// scroll-through have their own priors; the others, and any other name,
// share in-article's.
//
//	GeometryOf("scroll-through") // {PageWeight: 0.4, ReachAbove: 1, ReachBelow: 0.5}
func GeometryOf(format string) Geometry {
	switch format {
	case "fullscreen":
		return Geometry{PageWeight: 0.9, ReachAbove: 1, ReachBelow: 0.5}
	case "scroll-through":
		return Geometry{PageWeight: 0.4, ReachAbove: 1, ReachBelow: 0.5}
	default:
		return Geometry{PageWeight: 0.6, ReachAbove: 1, ReachBelow: 0.5}
	}
}

// CoVisible is the window, in viewports either side of the slot, whose
// sensitive blocks are on screen with the ad.
const CoVisible = 1.0

// sensitive are the IAB Content Taxonomy 3.1 Sensitive Topics ids: the root
// and its children (checked against the OCaml taxonomy in the tests).
var sensitive = map[CategoryID]bool{
	"v9i3On": true, "Rm3SiT": true, "avbNf2": true, "XtODT3": true, "I4GWl6": true, "Z7rJBM": true,
	"HxqYV1": true, "pg0WhF": true, "j9PaO9": true, "mm3UXx": true, "6i4dB6": true, "8FD8nI": true,
}

type near struct {
	offset float64
	main   bool
	labels []Label
}

// matched pairs each slot block with the profile's block at the smallest
// SimHash distance within 3 bits; an unknown block is main content without
// labels (Slot.of_wire).
func matched(p *Profile, s *Slot) []near {
	out := make([]near, 0, len(s.Blocks))
	for _, sb := range s.Blocks {
		best, bestD := -1, 4
		for i := range p.Blocks {
			if d := bits.OnesCount64(p.Blocks[i].SimHash ^ sb.SimHash); d < bestD {
				best, bestD = i, d
			}
		}
		if best < 0 {
			out = append(out, near{offset: sb.Offset, main: true})
		} else {
			out = append(out, near{offset: sb.Offset, main: p.Blocks[best].Main, labels: p.Blocks[best].Labels})
		}
	}

	return out
}

func scoreIn(labels []Label, id CategoryID) float64 {
	for _, l := range labels {
		if l.ID == id {
			return float64(l.Score)
		}
	}

	return 0
}

// kernel is a block's weight at d viewports from the slot, exp(-|d| / reach),
// decaying slower above (read) than below: in-article gives 0.37 at d = -1
// and 0.14 at d = +1.
func kernel(g Geometry, d float64) float64 {
	if d < 0 {
		return math.Exp(-math.Abs(d) / g.ReachAbove)
	}

	return math.Exp(-math.Abs(d) / g.ReachBelow)
}

func idsOf(lists ...[]Label) []CategoryID {
	var ids []CategoryID
	for _, l := range lists {
		for _, x := range l {
			ids = append(ids, x.ID)
		}
	}
	slices.Sort(ids)

	return slices.Compact(ids)
}

// AtSlot writes into out the context of one ad slot rather than of the whole
// page (Slot.context, study/context_boundary.md §4), for [Rule.Check].
// Relevance blends the page with the main blocks around the slot; a
// Sensitive Topics label takes the worst of the page and of every block
// within [CoVisible] viewports: never averaged.
//
//	slot blocks (SimHash, d) ─▶ matched to the profile's blocks: nearest SimHash
//	                            within 3 bits; no match: main content, no labels
//	  │
//	  ├─ main blocks ─────────▶ relevance, per id on the page or on those blocks:
//	  │                           w*page + (1-w) * sum(k(d)*score) / sum(k(d))
//	  │                           k(d) = exp(-|d| / ReachAbove if d < 0, else ReachBelow)
//	  │                           w = PageWeight; no main block: the page's labels
//	  │
//	  └─ |d| <= CoVisible ────▶ suitability, per Sensitive Topics id on the page
//	     (widgets included)       or those blocks: the max of their scores
//
//	out.Labels = relevance minus the ids in suitability, then suitability
//
// Without slot blocks it is the page's own context.
func (p *Profile) AtSlot(s *Slot, format string, out *Profile) {
	g := GeometryOf(format)
	blocks := matched(p, s)
	out.Labels = out.Labels[:0]
	out.FetchedAt = p.FetchedAt

	var mainLabels [][]Label
	total := 0.0
	for _, b := range blocks {
		if b.main {
			total += kernel(g, b.offset)
			mainLabels = append(mainLabels, b.labels)
		}
	}
	var relevant []Label
	if total == 0 {
		relevant = p.Labels
	} else {
		for _, id := range idsOf(append([][]Label{p.Labels}, mainLabels...)...) {
			local := 0.0
			for _, b := range blocks {
				if b.main {
					local += kernel(g, b.offset) * scoreIn(b.labels, id)
				}
			}
			score := g.PageWeight*scoreIn(p.Labels, id) + (1-g.PageWeight)*local/total
			relevant = append(relevant, Label{ID: id, Score: float32(score)})
		}
	}

	visible := [][]Label{p.Labels}
	for _, b := range blocks {
		if math.Abs(b.offset) <= CoVisible {
			visible = append(visible, b.labels)
		}
	}
	var unsafe []Label
	for _, id := range idsOf(visible...) {
		if !sensitive[id] {
			continue
		}
		worst := 0.0
		for _, l := range visible {
			worst = math.Max(worst, scoreIn(l, id))
		}
		unsafe = append(unsafe, Label{ID: id, Score: float32(worst)})
	}
	for _, l := range relevant {
		if !slices.ContainsFunc(unsafe, func(u Label) bool { return u.ID == l.ID }) {
			out.Labels = append(out.Labels, l)
		}
	}
	out.Labels = append(out.Labels, unsafe...)
}
