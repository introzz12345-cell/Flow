# Flow

Mobile-first web app with light / dark mode.

## Dark mode

- **อัตโนมัติ (default)** – follows the device setting (`prefers-color-scheme`) and switches live when the phone changes.
- **สลับเอง** – the sun/moon button in the header, or the อัตโนมัติ / สว่าง / มืด selector. The choice is saved in `localStorage` (`flow-theme`).
- No white flash on load: an inline script in `<head>` applies the saved theme before first paint.
- The mobile browser/status bar colour (`theme-color`) follows the active theme.

### Files

| File | Purpose |
| --- | --- |
| `css/theme.css` | Colour tokens (CSS variables) for light and dark |
| `css/style.css` | Layout and components, using the tokens only |
| `js/theme.js` | Theme logic – `FlowTheme.get()`, `FlowTheme.set("system" \| "light" \| "dark")`, `FlowTheme.toggle()` |

To add new UI, use the variables in `css/theme.css` (e.g. `var(--surface)`, `var(--text)`) instead of hard-coded colours, and it will work in both themes automatically.

## Run

Open `index.html` in a browser, or serve the folder:

```sh
npx serve .
```
