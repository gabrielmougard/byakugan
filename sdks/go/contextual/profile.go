package contextual

import (
	"errors"
	"math"
	"unsafe"

	"google.golang.org/protobuf/encoding/protowire"
)

// CategoryID is an IAB Content Taxonomy 3.1 id (cattax 9), e.g. "483"
// (Sports) or "v9i3On" (Sensitive Topics).
type CategoryID string

// Label is a category of a page and its score, calibrated to [0, 1].
type Label struct {
	ID    CategoryID
	Score float32
}

// Block is one labelled block of the page (a paragraph, a heading, a
// widget), known by the SimHash of its words; [Profile.AtSlot] matches the
// blocks a bid request says surround the slot against these.
type Block struct {
	SimHash uint64
	Main    bool    // main content; false for navigation, widgets, comments
	Labels  []Label // ancestors included, as for the page
	Top     float32 // its middle, viewports from the top, as the crawler estimated it

	start, end int // into Profile.blockLabels while decoding
}

// AdSlot is an ad container of the page: the element id a GPID ends with,
// and where it sits, viewports from the top, as the crawler estimated it.
type AdSlot struct {
	ID  string
	Top float32
}

// Profile is a page's contextual profile (src/protos/contextual/v1/
// profile.proto). Labels come highest score first, at most 20, and every
// label's ancestors are in the list too, with at least its score.
type Profile struct {
	Labels    []Label
	Blocks    []Block
	AdSlots   []AdSlot
	FetchedAt int64 // Unix seconds

	blockLabels []Label // one backing array for every block's labels
}

var errMalformed = errors.New("contextual: malformed profile")

// Decode parses the protobuf PageProfile b into p, reusing p's slices, so a
// warm Profile decodes without allocating. Label and ad slot ids point into
// b: b must not be modified while p is in use. Fields it does not use are
// skipped.
func (p *Profile) Decode(b []byte) error {
	p.Labels = p.Labels[:0]
	p.Blocks = p.Blocks[:0]
	p.AdSlots = p.AdSlots[:0]
	p.blockLabels = p.blockLabels[:0]
	p.FetchedAt = 0
	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			return errMalformed
		}
		b = b[n:]
		switch {
		case num == 1 && typ == protowire.BytesType: // labels
			v, n := protowire.ConsumeBytes(b)
			if n < 0 {
				return errMalformed
			}
			label, err := decodeLabel(v)
			if err != nil {
				return err
			}
			p.Labels = append(p.Labels, label)
			b = b[n:]
		case num == 6 && typ == protowire.BytesType: // blocks
			v, n := protowire.ConsumeBytes(b)
			if n < 0 {
				return errMalformed
			}
			if err := p.decodeBlock(v); err != nil {
				return err
			}
			b = b[n:]
		case num == 7 && typ == protowire.BytesType: // ad_slots
			v, n := protowire.ConsumeBytes(b)
			if n < 0 {
				return errMalformed
			}
			slot, err := decodeAdSlot(v)
			if err != nil {
				return err
			}
			p.AdSlots = append(p.AdSlots, slot)
			b = b[n:]
		case num == 3 && typ == protowire.VarintType: // fetched_at
			v, n := protowire.ConsumeVarint(b)
			if n < 0 {
				return errMalformed
			}
			p.FetchedAt = int64(v)
			b = b[n:]
		default:
			n := protowire.ConsumeFieldValue(num, typ, b)
			if n < 0 {
				return errMalformed
			}
			b = b[n:]
		}
	}

	// Slices into blockLabels only once it has stopped growing.
	for i := range p.Blocks {
		p.Blocks[i].Labels = p.blockLabels[p.Blocks[i].start:p.Blocks[i].end]
	}

	return nil
}

func (p *Profile) decodeBlock(b []byte) error {
	block := Block{start: len(p.blockLabels)}
	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			return errMalformed
		}
		b = b[n:]
		switch {
		case num == 1 && typ == protowire.Fixed64Type: // simhash
			v, n := protowire.ConsumeFixed64(b)
			if n < 0 {
				return errMalformed
			}
			block.SimHash = v
			b = b[n:]
		case num == 2 && typ == protowire.VarintType: // main
			v, n := protowire.ConsumeVarint(b)
			if n < 0 {
				return errMalformed
			}
			block.Main = v != 0
			b = b[n:]
		case num == 3 && typ == protowire.BytesType: // labels
			v, n := protowire.ConsumeBytes(b)
			if n < 0 {
				return errMalformed
			}
			label, err := decodeLabel(v)
			if err != nil {
				return err
			}
			p.blockLabels = append(p.blockLabels, label)
			b = b[n:]
		case num == 4 && typ == protowire.Fixed32Type: // top
			v, n := protowire.ConsumeFixed32(b)
			if n < 0 {
				return errMalformed
			}
			block.Top = math.Float32frombits(v)
			b = b[n:]
		default:
			n := protowire.ConsumeFieldValue(num, typ, b)
			if n < 0 {
				return errMalformed
			}
			b = b[n:]
		}
	}
	block.end = len(p.blockLabels)
	p.Blocks = append(p.Blocks, block)

	return nil
}

func decodeAdSlot(b []byte) (AdSlot, error) {
	var slot AdSlot
	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			return AdSlot{}, errMalformed
		}
		b = b[n:]
		switch {
		case num == 1 && typ == protowire.BytesType: // id
			v, n := protowire.ConsumeBytes(b)
			if n < 0 {
				return AdSlot{}, errMalformed
			}
			slot.ID = unsafe.String(unsafe.SliceData(v), len(v)) //nolint:gosec // b outlives p, see Decode
			b = b[n:]
		case num == 2 && typ == protowire.Fixed32Type: // top
			v, n := protowire.ConsumeFixed32(b)
			if n < 0 {
				return AdSlot{}, errMalformed
			}
			slot.Top = math.Float32frombits(v)
			b = b[n:]
		default:
			n := protowire.ConsumeFieldValue(num, typ, b)
			if n < 0 {
				return AdSlot{}, errMalformed
			}
			b = b[n:]
		}
	}

	return slot, nil
}

func decodeLabel(b []byte) (Label, error) {
	var label Label
	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			return Label{}, errMalformed
		}
		b = b[n:]
		switch {
		case num == 1 && typ == protowire.BytesType: // id
			v, n := protowire.ConsumeBytes(b)
			if n < 0 {
				return Label{}, errMalformed
			}
			if len(v) > 0 {
				// The id stays in b instead of being copied: decoding a
				// profile per bid request must not allocate.
				label.ID = CategoryID(unsafe.String(unsafe.SliceData(v), len(v))) //nolint:gosec // b outlives p, see Decode
			}
			b = b[n:]
		case num == 2 && typ == protowire.Fixed32Type: // score
			v, n := protowire.ConsumeFixed32(b)
			if n < 0 {
				return Label{}, errMalformed
			}
			label.Score = math.Float32frombits(v)
			b = b[n:]
		default:
			n := protowire.ConsumeFieldValue(num, typ, b)
			if n < 0 {
				return Label{}, errMalformed
			}
			b = b[n:]
		}
	}

	return label, nil
}

// Score is a category's score on the page, 0 when it is not there.
func (p *Profile) Score(id CategoryID) float32 {
	for _, l := range p.Labels {
		if l.ID == id {
			return l.Score
		}
	}

	return 0
}
