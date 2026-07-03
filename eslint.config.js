import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import prettier from 'eslint-config-prettier';

// Flat config (ESLint 9). Lints the sandbox TypeScript target; ignores tooling,
// harness scripts, and per-task worktrees. Prettier-conflicting rules disabled last.
export default tseslint.config(
  {
    ignores: [
      'node_modules/**',
      'dist/**',
      '.claude/**',
      '.harness/**',
      '*.config.ts',
      'eslint.config.js',
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  prettier,
);
