# Publish MoveGrow on GitHub

The intended public repository is:

`https://github.com/seesaw-earth/MoveGrow`

The repository name was not found in the GitHub repository search when this package was prepared on September 29, 2026.

## Automated path on your Mac

From the unzipped project root, with GitHub CLI installed and authenticated:

```bash
./Scripts/publish-github.sh
```

The script will:

1. initialize a local `main` Git repository if needed;
2. commit the current source;
3. create `seesaw-earth/MoveGrow` as a **public** repository and push it;
4. configure GitHub Pages from the `/docs` folder;
5. print the expected privacy, support, and home URLs.

Do **not** create the `v1.0.0` tag until the public source exactly matches the Xcode archive submitted to App Store Connect.

## Expected public URLs

- Repository: `https://github.com/seesaw-earth/MoveGrow`
- Privacy: `https://seesaw-earth.github.io/MoveGrow/privacy.html`
- Support: `https://seesaw-earth.github.io/MoveGrow/support.html`
- Marketing/home: `https://seesaw-earth.github.io/MoveGrow/`

GitHub Pages can take a short period to become reachable after its first deployment.
