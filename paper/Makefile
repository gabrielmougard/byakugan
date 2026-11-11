# The paper: make writes out/main.pdf. Needs Tectonic (brew install tectonic),
# which fetches the TeX packages it needs on first use.
#   make            the PDF
#   make check S="05-cascade 09-evaluation"   only those sections, into .check/
#   make arxiv      out/arxiv.tar.gz: sources plus the .bbl arXiv asks for

out/main.pdf: main.tex preamble.tex sections/*.tex *.bib
	mkdir -p out
	tectonic -X compile --outdir out main.tex

check:
	./check.sh $(S)

arxiv: out/main.pdf
	rm -rf .arxiv && mkdir -p .arxiv/sections
	tectonic -X compile --keep-intermediates --outdir .arxiv main.tex
	cp main.tex preamble.tex .arxiv/ && cp sections/*.tex .arxiv/sections/
	cd .arxiv && rm -f *.aux *.log *.out *.toc *.blg *.xdv main.pdf && tar czf ../out/arxiv.tar.gz .
	rm -rf .arxiv

clean:
	rm -rf out .check .arxiv

.PHONY: check arxiv clean
