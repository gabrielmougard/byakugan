package contextual

// SensitiveTopics is the IAB Content Taxonomy 3.1 branch brand suitability
// avoids.
const SensitiveTopics CategoryID = "v9i3On"

// DefaultMinScore is the score from which a label counts as on the page,
// the OCaml matcher's threshold.
const DefaultMinScore = 0.5

// Rule is a curated deal's context, the OCaml matcher's refusal
// (src/lib/matcher.ml) in Go: none of Blocks on the page, no Sensitive
// Topics if AvoidSensitive, and one of Targets if any are set. A category
// counts with its descendants, from MinScore up.
type Rule struct {
	Targets        []CategoryID
	Blocks         []CategoryID
	AvoidSensitive bool
	// MinScore is DefaultMinScore when 0. Raise it to be stricter (a deal
	// ahead of pace), lower it to reach more pages (behind pace).
	MinScore float32
}

// Verdict is the outcome of a [Rule] on a page.
type Verdict uint8

const (
	Eligible   Verdict = iota // the rule holds
	Blocked                   // a blocked category is on the page
	Unsuitable                // Sensitive Topics are on the page and the rule avoids them
	OffTarget                 // the rule has targets and none is on the page
)

func (v Verdict) String() string {
	switch v {
	case Eligible:
		return "eligible"
	case Blocked:
		return "blocked"
	case Unsuitable:
		return "unsuitable"
	case OffTarget:
		return "off-target"
	default:
		return "unknown"
	}
}

// Decision is a verdict and the label behind it: the blocked or sensitive
// category, or the target that matched. Label is empty when no label
// decided (no targets, or none on the page).
type Decision struct {
	Verdict Verdict
	Label   Label
}

// Check applies r to a page's profile, in the OCaml matcher's order:
// blocks, then Sensitive Topics, then targets. It does not allocate.
//
// Profiles carry every label's ancestors, so a category is on the page,
// itself or through a descendant, exactly when its own id is there.
func (r *Rule) Check(p *Profile) Decision {
	minScore := r.MinScore
	if minScore == 0 {
		minScore = DefaultMinScore
	}
	for _, id := range r.Blocks {
		if label, ok := p.present(id, minScore); ok {
			return Decision{Verdict: Blocked, Label: label}
		}
	}
	if r.AvoidSensitive {
		if label, ok := p.present(SensitiveTopics, minScore); ok {
			return Decision{Verdict: Unsuitable, Label: label}
		}
	}
	if len(r.Targets) == 0 {
		return Decision{Verdict: Eligible}
	}
	for _, id := range r.Targets {
		if label, ok := p.present(id, minScore); ok {
			return Decision{Verdict: Eligible, Label: label}
		}
	}

	return Decision{Verdict: OffTarget}
}

func (p *Profile) present(id CategoryID, minScore float32) (Label, bool) {
	for _, l := range p.Labels {
		if l.ID == id && l.Score >= minScore {
			return l, true
		}
	}

	return Label{}, false
}
