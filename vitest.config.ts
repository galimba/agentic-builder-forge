import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['sandbox/**/*.test.ts'],
    environment: 'node',
  },
});
