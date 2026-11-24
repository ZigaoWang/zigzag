# Notes for extension authors

## Links taken off on purpose

Some extensions and sites take the `href` off a link so a plain click opens their own viewer instead of the page.
Without an `href`, a ⌘-click or middle-click has nothing to open.

Keep the address in `data-zigzag-href` on the same `<a>`:

```js
link.setAttribute("data-zigzag-href", link.getAttribute("href"));
link.removeAttribute("href");
```

On a ⌘ or middle press on that link, Zigzag puts the address back in `href` and WebKit opens it as it would any link:
middle-click in a background tab, ⌘-click in a tab, with the page's history and referrer. Zigzag also sets
`data-zigzag-modified` on the link for that press. Your click handler can stand aside while the mark is there:

```js
link.addEventListener("click", (event) => {
  if (event.target.closest("a[data-zigzag-modified]")) return;
  event.preventDefault();
  openViewer();
});
```

Two seconds later Zigzag removes the mark, and the `href` too if it's still the one it put back.

- Only a ⌘ press or the middle button. A plain click, and ⇧ or ⌥ clicks, stay yours.
- Only http and https addresses, relative ones included. Anything else is left alone.
- Keep the attribute current when you reuse the element for another page, or remove it.
- It is not a security boundary: the page can read and change it, as it can any link.
