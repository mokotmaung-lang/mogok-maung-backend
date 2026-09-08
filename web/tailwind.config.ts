import type { Config } from 'tailwindcss';

const config: Config = {
  content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}', './lib/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        brand: {
          navy: '#0F172A',
          panel: '#1E293B',
          edge: '#334155',
          amber: '#F59E0B',
          blue: '#3B82F6',
        },
      },
    },
  },
  plugins: [],
};

export default config;