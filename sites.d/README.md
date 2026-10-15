# Site registry

One JSON file per site. A site file says **where a credential gets typed**, so it carries
the same authority as the credential itself. That is why:

- only the template is committed; real `*.json` files are gitignored,
- the installer copies them to the root-owned install dir, and
- adding or changing a site means re-running `sudo bash setup/install.sh`.

Copy `EXAMPLE-ats.json.template` to `<site>.json`, fill in the login URL, the expected
origin, the three selectors, a success selector (and optionally `success_cookie`), and the
`op://secure-browser/<item title>/<field>` references. Keep selectors specific: the helper
takes the first *visible* match for each.
