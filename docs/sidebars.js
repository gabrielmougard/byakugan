// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
module.exports = {
  main: [
    { type: 'doc', id: 'README', label: 'Overview' },
    {
      type: 'category',
      label: 'Guide',
      collapsed: false,
      items: [
        'docs/guide/quickstart',
        'docs/guide/placement-lab',
        'docs/guide/api',
        'docs/guide/configuration',
        'docs/guide/code-map',
        'docs/guide/deploy',
      ],
    },
    {
      type: 'category',
      label: 'Study',
      collapsed: false,
      items: [
        { type: 'doc', id: 'study/architecture', label: 'Offline path' },
        { type: 'doc', id: 'study/matching', label: 'Online matching' },
        { type: 'doc', id: 'study/context_boundary', label: 'Context boundary' },
        { type: 'doc', id: 'study/t4_models', label: 'T4 model choice' },
        { type: 'doc', id: 'study/robots_matcher', label: 'robots.txt and AI-use gate' },
        { type: 'doc', id: 'study/html_parser', label: 'HTML extraction' },
        { type: 'doc', id: 'study/model2vec_c', label: 'Model2Vec in C' },
        { type: 'doc', id: 'study/siglip2_images', label: 'Images with SigLIP 2' },
        { type: 'doc', id: 'study/literature', label: 'Literature' },
      ],
    },
    { type: 'doc', id: 'ROADMAP', label: 'Roadmap' },
  ],
};
