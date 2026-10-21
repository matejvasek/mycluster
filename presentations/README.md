# Libvirt SNO test-lab slides

`libvirt-sno-testing.tex` is a ten-slide English Beamer presentation for
technical colleagues. It explains provisioning and operating the lab, not a
workload test suite or a personal test workflow. Commands on the slides are
examples to discuss, not commands run by building the document.

## Build the neutral deck

Use a TeX installation with Beamer, PGF/TikZ, and standard fonts (for example,
TeX Live). From the repository root:

```sh
mkdir -p /tmp/libvirt-sno-slides
pdflatex -halt-on-error -interaction=nonstopmode \
  -output-directory=/tmp/libvirt-sno-slides presentations/libvirt-sno-testing.tex
pdflatex -halt-on-error -interaction=nonstopmode \
  -output-directory=/tmp/libvirt-sno-slides presentations/libvirt-sno-testing.tex
```

Alternatively, with Tectonic (first use needs network access to its TeX bundle):

```sh
mkdir -p /tmp/libvirt-sno-slides
tectonic --outdir /tmp/libvirt-sno-slides presentations/libvirt-sno-testing.tex
```

Open `/tmp/libvirt-sno-slides/libvirt-sno-testing.pdf`. Keep PDFs and auxiliary
files outside the repository; commit only the authored sources. The default
Madrid theme uses a neutral blue palette and needs no external theme, brand
assets, or Red Hat fonts. XeLaTeX can also build the neutral source.

## Optional unofficial theme

The [openshift/ci-docs Beamer theme](https://github.com/openshift/ci-docs/tree/main/presentations/beamer)
is explicitly **unofficial**, not an official Red Hat presentation template.
The default deck does not download or bundle it, logos, or fonts.

To opt in, obtain `beamerthemeredhat.sty` from that source and, separately,
permission to use the required logo files. Install **Red Hat Text** and
**Red Hat Mono** fonts. Make the style file discoverable through `TEXINPUTS`.
From a working directory containing your permitted `img/logo.png` and
`img/logo_white.png`, run XeLaTeX twice, adapting these absolute paths:

```sh
mkdir -p /tmp/libvirt-sno-slides
TEXINPUTS="/path/to/ci-docs/presentations/beamer:${TEXINPUTS:-}:" \
  xelatex -halt-on-error -interaction=nonstopmode \
  -output-directory=/tmp/libvirt-sno-slides -jobname=libvirt-sno-testing \
  '\def\UseUnofficialRedHatTheme{1}\input{/path/to/mycluster/presentations/libvirt-sno-testing.tex}'
```

The opt-in checks for XeTeX, the style file, both logo files, and both font
families before loading the theme. Missing prerequisites produce a warning
and the neutral fallback. No theme assets need to be copied into this repo.

## Factual scope

Slide footers link to the public sources:

- [README.md](https://github.com/matejvasek/mycluster/blob/master/README.md):
  prerequisites, defaults, deployment, smoke checks, options, caveats, lifecycle.
- [deploy-sno.sh](https://github.com/matejvasek/mycluster/blob/master/deploy-sno.sh):
  configuration precedence, topology, function order, ISO caching, destructive
  VM recreation, and optional LVMS/registry behavior.
- [.gitignore](https://github.com/matejvasek/mycluster/blob/master/.gitignore):
  local inputs and generated artifacts excluded from version control.

Defaults are not requirements; adapt names, addressing, paths, and sizing.
Additional operational advice is explicitly labeled as a suggestion.
Never paste local pull secrets, private keys, kubeconfigs, passwords, or OAuth
credentials into the slides. No live deployment is needed to build the deck.
