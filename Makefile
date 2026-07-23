# Rain-sounds long-form video pipeline.
# Every stage keeps its state in files under build/ and output/, so runs are
# resumable and only stale stages rebuild.

SHELL := /bin/bash

VISUAL := build/loop_visual.mp4
AUDIO  := build/loop_audio.m4a
CONFIG := config/project.json

.PHONY: all visual audio render sample preview clean help

help:
	@echo "Rain-sounds pipeline targets:"
	@echo "  make visual   - build the seamless looping rain visual (build/loop_visual.mp4)"
	@echo "  make audio    - build the seamless looping rain audio  (build/loop_audio.m4a)"
	@echo "  make render   - stitch loops into the full-length MP4  (output/)"
	@echo "  make all      - visual + audio + render"
	@echo "  make sample   - build loops + a 30s preview (output/sample.mp4)"
	@echo "  make preview  - alias for 'make sample'"
	@echo "  make clean    - remove build/ and output/ artifacts"
	@echo ""
	@echo "Config lives in $(CONFIG). Set FORCE=1 to rebuild a fresh stage,"
	@echo "or DURATION=<seconds> to override the render length for a quick test."

all: render

$(VISUAL): $(CONFIG) scripts/make_visual.sh scripts/gen_rain_texture.py scripts/lib.sh
	./scripts/make_visual.sh

$(AUDIO): $(CONFIG) scripts/make_audio.sh scripts/lib.sh
	./scripts/make_audio.sh

visual: $(VISUAL)
audio:  $(AUDIO)

render: $(VISUAL) $(AUDIO)
	./scripts/render.sh

sample: $(VISUAL) $(AUDIO)
	DURATION=30 OUT_NAME=sample.mp4 ./scripts/render.sh
	@echo "Preview at output/sample.mp4"

preview: sample

clean:
	rm -rf build/* output/*
	@echo "cleaned build/ and output/"
