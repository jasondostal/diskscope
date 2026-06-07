# DiskScope — build, test, package.
.PHONY: help app dmg notarize icon run test clean

help:
	@echo "DiskScope make targets:"
	@echo "  make app       build + sign + verify dist/DiskScope.app"
	@echo "  make dmg       …and a distributable DMG"
	@echo "  make notarize  …and notarize + staple (needs Developer ID + NOTARY_PROFILE)"
	@echo "  make icon      regenerate Packaging/AppIcon.icns"
	@echo "  make run       build + launch the app (dev loop)"
	@echo "  make test      swift test"
	@echo "  make clean     remove build + dist artifacts"

app:
	bash Scripts/package.sh

dmg:
	bash Scripts/package.sh --dmg

notarize:
	bash Scripts/package.sh --dmg --notarize

icon:
	bash Scripts/make-icon.sh

run:
	swift build --product DiskScopeApp && .build/debug/DiskScopeApp

test:
	swift test

clean:
	rm -rf dist Packaging/AppIcon.iconset Packaging/icon-1024.png
	swift package clean
