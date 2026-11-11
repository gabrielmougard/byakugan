// @ts-check
// The docs root is the repository itself: README.md, ROADMAP.md and study/ are
// rendered where they live (one copy, links that also work on GitHub), and
// the guide pages written for this site sit in docs/guide/.

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Byakugan',
  tagline: 'Byakugan: contextual classification and ad placement, in OCaml',
  url: 'http://localhost',
  baseUrl: '/',
  favicon: 'img/byakugan-mark.svg',
  onBrokenLinks: 'throw',
  markdown: {
    format: 'detect',
    hooks: { onBrokenMarkdownLinks: 'throw' },
  },
  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          path: '..',
          include: ['README.md', 'ROADMAP.md', 'study/*.md', 'docs/guide/*.md'],
          // private studies, git-ignored: never rendered even when present locally
          exclude: ['study/pages.md', 'study/reach.md', 'study/revenue.md', 'study/supply.md'],
          routeBasePath: '/',
          sidebarPath: './sidebars.js',
        },
        blog: false,
        pages: false,
        theme: { customCss: './src/css/custom.css' },
      }),
    ],
  ],
  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      colorMode: { respectPrefersColorScheme: true },
      navbar: {
        title: 'Byakugan',
        logo: { alt: 'Byakugan', src: 'img/byakugan-mark.svg' },
        items: [
          { to: '/', label: 'Overview', position: 'left' },
          { to: '/guide/quickstart', label: 'Guide', position: 'left' },
          { to: '/study/architecture', label: 'Study', position: 'left' },
          { to: '/ROADMAP', label: 'Roadmap', position: 'left' },
        ],
      },
      prism: { additionalLanguages: ['ocaml', 'bash', 'json'] },
    }),
};

module.exports = config;
