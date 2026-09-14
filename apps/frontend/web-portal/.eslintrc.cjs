// B-04 fix: `npm run lint` (called by ci-frontend.yml) had no config to read at all, so ESLint
// itself failed before checking a single file. This is the standard config for the
// vite-react-ts template — matches the eslint@8 devDependency already in package.json
// (ESLint 9's flat config uses eslint.config.js instead; this project pins ESLint 8).
module.exports = {
  root: true,
  env: { browser: true, es2021: true },
  extends: [
    'eslint:recommended',
    'plugin:@typescript-eslint/recommended',
    'plugin:react-hooks/recommended',
  ],
  ignorePatterns: ['dist', '.eslintrc.cjs', 'vite.config.ts'],
  parser: '@typescript-eslint/parser',
  plugins: ['react-refresh'],
  rules: {
    'react-refresh/only-export-components': ['warn', { allowConstantExport: true }],
    '@typescript-eslint/no-unused-vars': ['warn', { argsIgnorePattern: '^_' }],
  },
};
