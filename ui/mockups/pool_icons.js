// PROTOTYPE: Knowledge Pool's in-house icons, drawn on a 24px grid in one ink stroke.
// Shapes with class "f" take a fill in the Block treatment; the second class names the fill.
const ICONS = {
  deck: { name: 'Deck', means: 'A deck; the Decks tab.',
    svg: '<path class="f w" d="M7 7V4.5h10V7"/><rect class="f s" x="5" y="7" width="14" height="13" rx="2"/><path d="M5 11h14"/>' },
  collection: { name: 'Collection', means: 'Your cards, or someone else’s; the Collection tab.',
    svg: '<rect class="f s" x="5" y="3" width="14" height="18" rx="2"/><path d="M9 3v18"/><path class="f u" d="M12 6.5h4v4.5h-4z"/><path class="f r" d="M12 13h4v4.5h-4z"/>' },
  quest: { name: 'Quest list', means: 'Cards your decks still need; the Quests tab.',
    svg: '<path class="f w" d="M3 6.5l6-2 6 2 6-2v13l-6 2-6-2-6 2z"/><path d="M5.5 16c1.5-2 3-.5 4.5-2.5s2.5-2 4-3" stroke-dasharray="1.6 2.2"/><path d="M16 7l3 3M19 7l-3 3"/>' },
  people: { name: 'People', means: 'Other users in the pool.',
    svg: '<circle class="f s" cx="9" cy="8" r="3.2"/><path class="f s" d="M3.5 19.5c.5-3.6 3-5.7 5.5-5.7s5 2.1 5.5 5.7z"/><circle cx="16.8" cy="8.8" r="2.6"/><path d="M16 13.7c2.5-.3 4.5 1.6 4.9 5"/>' },
  sleeveable: { name: 'Sleeveable', means: 'You own every card this deck plays. Shuffle up.',
    svg: '<rect x="7.5" y="2.5" width="9" height="13" rx="1.2"/><path class="f ok" d="M5 7.5h14v12A1.5 1.5 0 0 1 17.5 21h-11A1.5 1.5 0 0 1 5 19.5z"/><path d="M9 14.2l2.1 2.1 3.9-4.3"/>' },
  missing: { name: 'Missing', means: 'Copies this deck plays that its owner doesn’t have. Shown with the count.',
    svg: '<rect class="f warn" x="5.5" y="3" width="13" height="18" rx="2" stroke-dasharray="3.2 2.4"/><path d="M9 12h6"/>' },
  unfinished: { name: 'Unfinished', means: 'The deck holds fewer cards than its format needs. The wedge fills as it grows.',
    svg: '' /* drawn by gauge() */ },
  legal: { name: 'Legal', means: 'Passes its format’s rules.',
    svg: '<path class="f ok" d="M12 3l7 3v5.2c0 4.4-3 7.9-7 9.8-4-1.9-7-5.4-7-9.8V6z"/><path d="M8.7 12l2.3 2.3 4.3-4.6"/>' },
  illegal: { name: 'Not legal', means: 'Breaks a format rule. The reason is always written next to it.',
    svg: '<path class="f bad" d="M12 3l7 3v5.2c0 4.4-3 7.9-7 9.8-4-1.9-7-5.4-7-9.8V6z"/><path d="M9.5 9.5l5 5M14.5 9.5l-5 5"/>' },
  trade: { name: 'Has what you need', means: 'Another user owns cards your quest list wants.',
    svg: '<path d="M4 8.5h14.5L15 5M20 15.5H5.5L9 19"/>' },
  copy: { name: 'Copy', means: 'Make your own copy of someone’s deck.',
    svg: '<path d="M5 17V4.5A1.5 1.5 0 0 1 6.5 3H15"/><rect class="f s" x="8" y="6.5" width="11" height="14.5" rx="1.5"/>' },
  got: { name: 'Got it', means: 'Add a card from the quest list to your collection.',
    svg: '<rect class="f s" x="4.5" y="3" width="11" height="15" rx="1.5"/><path class="f ok" d="M18 13.5a3.5 3.5 0 1 1 0 7 3.5 3.5 0 0 1 0-7z"/><path d="M18 15.3v3.4M16.3 17h3.4"/>' },
  filter: { name: 'Filter', means: 'Narrow a list by colour, type, format or status.',
    svg: '<path class="f s" d="M4 5h16l-6 7.5V19l-4 1.5v-8z"/>' },
  sort: { name: 'Sort', means: 'Change the order of a list.',
    svg: '<path d="M8 4v16M4.5 16.5L8 20l3.5-3.5M16 20V4M12.5 7.5L16 4l3.5 3.5"/>' },
  group: { name: 'Group', means: 'Split a list into headed sections.',
    svg: '<rect class="f u" x="4" y="4" width="16" height="6.5" rx="1.5"/><rect class="f r" x="4" y="13.5" width="16" height="6.5" rx="1.5"/>' },
  search: { name: 'Search', means: 'Find a card by name.',
    svg: '<circle class="f s" cx="10.5" cy="10.5" r="6.2"/><path d="M15.2 15.2l5 5"/>' },
  stats: { name: 'Stats', means: 'A deck’s curve and colours.',
    svg: '<path d="M3.5 20.5h17"/><rect class="f u" x="5.5" y="12" width="3.4" height="6"/><rect class="f r" x="10.3" y="6.5" width="3.4" height="11.5"/><rect class="f g" x="15.1" y="9.5" width="3.4" height="8.5"/>' },
  changes: { name: 'Changes', means: 'A deck’s history of change notes.',
    svg: '<path d="M4.2 13a8 8 0 1 0 2.3-6.8"/><path d="M4.5 3.5v4h4"/><path d="M12 8v4.5l3 2"/>' },
  lock: { name: 'Locked', means: 'Your deck or collection is read-only until you tap Edit.',
    svg: '<path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/><rect class="f s" x="5" y="10.5" width="14" height="10" rx="2"/><path d="M12 14.5v2.5"/>' },
  unlock: { name: 'Editing', means: 'Changes are on. Each one saves with a change note.',
    svg: '<path d="M8 10.5V8a4 4 0 0 1 7.7-1.6"/><rect class="f warn" x="5" y="10.5" width="14" height="10" rx="2"/><path d="M12 14.5v2.5"/>' },
  swipe: { name: 'Swipe', means: 'This page has neighbours to the left and right.',
    svg: '<path d="M4 12h16M7.5 8.5L4 12l3.5 3.5M16.5 8.5L20 12l-3.5 3.5"/>' },
};
// The unfinished gauge: a ring with a wedge for how full the deck is.
function gauge(frac) {
  const f = Math.max(0, Math.min(1, frac)), a = f * 2 * Math.PI, r = 8.5;
  const x = 12 + r * Math.sin(a), y = 12 - r * Math.cos(a), big = f > .5 ? 1 : 0;
  const wedge = f >= 1 ? `<circle class="f u" cx="12" cy="12" r="${r}"/>` : f <= 0 ? '' : `<path class="f u" d="M12 12V${12 - r}A${r} ${r} 0 ${big} 1 ${x.toFixed(2)} ${y.toFixed(2)}z"/>`;
  return `${wedge}<circle cx="12" cy="12" r="${r}"/>`;
}
function icon(name, extra = '') {
  const inner = name === 'unfinished' ? gauge(typeof extra === 'number' ? extra : .42) : ICONS[name].svg;
  return `<svg class="ic" viewBox="0 0 24 24" aria-hidden="true" focusable="false">${inner}</svg>`;
}
const ICON_CSS = `
.ic { width: 1.35em; height: 1.35em; flex: none; vertical-align: -0.3em; fill: none; stroke: currentColor; stroke-width: 2.1; stroke-linecap: round; stroke-linejoin: round; }
.ic .f { fill: none; }
.block .ic .f.s { fill: var(--surface); } .block .ic .f.w { fill: var(--mana-w); } .block .ic .f.u { fill: var(--mana-u); }
.block .ic .f.r { fill: var(--mana-r); } .block .ic .f.g { fill: var(--mana-g); }
.block .ic .f.ok { fill: var(--ok-bg); } .block .ic .f.warn { fill: var(--warn-bg); } .block .ic .f.bad { fill: var(--bad-bg); }
.outline .ic .f.u { fill: currentColor; fill-opacity: .3; }
`;
