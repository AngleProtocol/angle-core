module.exports = {
  parser: '@typescript-eslint/parser',
  extends: [
    'standard',
    'plugin:promise/recommended',
    'plugin:@typescript-eslint/eslint-recommended',
    'plugin:@typescript-eslint/recommended',
    'plugin:prettier/recommended',
  ],
  plugins: ['mocha-no-only', 'promise', 'prettier', '@typescript-eslint'],
  env: {
    browser: true,
    node: true,
    mocha: true,
    jest: true,
  },
  globals: {
    artifacts: false,
    contract: false,
    assert: false,
    web3: false,
    usePlugin: false,
    extendEnvironment: false,
  },
  rules: {
    // Strict mode
    strict: ['error', 'global'],
    'prettier/prettier': 'error',
    // Code style
    'array-bracket-spacing': ['off'],
    camelcase: [
      'error',
      { properties: 'always', ignoreImports: true, allow: ['(.*?)__factory'] },
    ],
    'comma-dangle': ['error', 'always-multiline'],
    'comma-spacing': ['error', { before: false, after: true }],
    'dot-notation': ['error', { allowKeywords: true, allowPattern: '' }],
    'eol-last': ['error', 'always'],
    eqeqeq: ['error', 'smart'],
    'generator-star-spacing': ['error', 'before'],
    'linebreak-style': ['error', 'unix'],
    'max-len': ['error', 150, 2, { ignoreComments: true }],
    'no-debugger': 'off',
    'no-dupe-args': 'error',
    'no-dupe-keys': 'error',
    'no-mixed-spaces-and-tabs': ['error', 'smart-tabs'],
    'no-redeclare': ['error', { builtinGlobals: true }],
    'no-trailing-spaces': ['error', { skipBlankLines: false }],
    'no-undef': 'error',
    'no-use-before-define': 'off',
    'no-var': 'error',
    'object-curly-spacing': ['error', 'always'],
    'prefer-const': 'error',
    quotes: ['error', 'single'],
    semi: ['error', 'always'],
    'space-before-function-paren': 0,
    '@typescript-eslint/no-non-null-assertion': 0,

    'mocha-no-only/mocha-no-only': ['error'],

    'promise/always-return': 'off',
    'promise/avoid-new': 'off',
  },
  overrides: [
    {
      files: ['*.js'],
      rules: {
        '@typescript-eslint/no-var-requires': [0],
      },
    },
    {
      files: ['./test/**/*'],
      rules: {
        camelcase: [0],
      },
    },
  ],
  parserOptions: {
    ecmaVersion: 2018,
  },
}
