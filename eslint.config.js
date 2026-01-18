import js from "@eslint/js";
import globals from "globals";

const recommended = js.configs.recommended;

export default [
    {
        ignores: [
            "**/*.min.js",
            "cps/static/js/libs/**",
            "cps/static/js/compress/**",
            "cps/static/js/reading/**",
            "cps/static/js/kthoom.js",
            "cps/static/js/service-worker.js",
        ],
    },
    {
        files: ["cps/static/js/**/*.js"],
        ...recommended,
        languageOptions: {
            ...recommended.languageOptions,
            ecmaVersion: 2021,
            sourceType: "script",
            globals: {
                ...globals.browser,
                ...globals.jquery,
            },
        },
        rules: {
            ...recommended.rules,

            // Keep this as a low-noise baseline first.
            "no-console": "off",
            "no-unused-vars": [
                "warn",
                { args: "none", varsIgnorePattern: "^_" },
            ],

            // Many of these scripts rely on globals injected by templates or
            // browser runtime, and some legacy files intentionally create
            // globals in sloppy mode.
            "no-undef": "off",
            "no-redeclare": "warn",
            "no-constant-binary-expression": "warn",
            "no-useless-escape": "warn",
            "no-empty": "warn",

            // Match existing style without forcing a big refactor.
            indent: ["warn", 4, { SwitchCase: 1 }],
            quotes: [
                "warn",
                "double",
                { avoidEscape: true, allowTemplateLiterals: true },
            ],
            semi: ["warn", "always"],
            eqeqeq: ["warn", "always"],
        },
    },
];
