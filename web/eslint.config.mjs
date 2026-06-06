import { FlatCompat } from "@eslint/eslintrc";

// ESLint 10 uses flat config. eslint-config-next is consumed through FlatCompat until it ships
// a native flat export. This keeps the Next core-web-vitals and TypeScript rules in force.
const compat = new FlatCompat({
  baseDirectory: import.meta.dirname,
});

const eslintConfig = [
  ...compat.extends("next/core-web-vitals", "next/typescript"),
  {
    ignores: [".next/**", "node_modules/**", "out/**"],
  },
];

export default eslintConfig;
