# Capacity Expansion Model Comparison website

This directory is the editable source for the public
[results website](https://nxshi.github.io/GenX_9n_WECC/).
It compares the EPRI results with the GenX K-means and sampled-week myopic
results for the five model years from 2025 through 2045.

## Directory contents

- `dist/` is the complete static website that is published.
- `dist/data/results-data.js` is the generated chart dataset.
- `dist/downloads/` contains the downloadable result workbooks.
- `tools/build_results_data.py` rebuilds the chart dataset from the EPRI
  workbook and GenX result folders.
- `tools/build_download_workbooks.py` rebuilds the downloadable workbooks.
- `.github/workflows/results-website.yml` validates, rebuilds, and publishes
  the site through GitHub Pages.

## Modify the website

Edit `dist/index.html`, `dist/compare.html`, `dist/site.css`, or `dist/app.js`,
then open `dist/index.html` locally to inspect the result. Commit the changed
source and generated files together so collaborators see the same website.

## Refresh the data

The data builder expects these items in the parent case directory:

- `Results_EPRI.xlsb`
- `results_kmeans_myopic/`
- `results_sampled_myopic/`

From this directory, create a Python environment and rebuild the chart data:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python tools/build_results_data.py --case-root .. --output dist/data/results-data.js
python tools/build_download_workbooks.py --data dist/data/results-data.js --output-dir dist/downloads
```

When adding another model result, add its directory, identifier, and display
name in `tools/build_results_data.py`, rebuild the data, and check both pages.
The interface reads its model-result choices from the generated dataset.

The downloadable workbooks are committed so the public links continue to
work. Rebuild them after changing the dataset.

## Publish changes

GitHub is the shared source of record. When relevant inputs, model results, or
website files are pushed to `main`, GitHub Actions rebuilds the generated data
and downloads, validates the site, and publishes `dist/` to GitHub Pages. The
workflow also commits refreshed generated files back to `main` when needed.

The deployment can also be started manually from the repository's **Actions**
tab by choosing **Publish model results website** and **Run workflow**.
