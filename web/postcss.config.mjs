// Tailwind v4 is configured through PostCSS with this single plugin. There is no
// tailwind.config.js in v4; the theme lives in CSS via the @theme block in app/globals.css.
const config = {
  plugins: {
    "@tailwindcss/postcss": {},
  },
};

export default config;
