# dmgbuild settings for the Aseprite disk image.
#
# Consumed by scripts/make-dmg.sh, which passes paths in through the
# environment so this file holds layout only and nothing build-specific.
#
# There is deliberately no custom background image. A DMG with installer
# artwork would read as an official Aseprite installer, and this repository is
# emphatically not one -- it only automates compiling from source for someone
# who already owns a license.

import os

application = os.environ["DMG_APP_PATH"]
readme = os.environ["DMG_README_PATH"]

app_name = os.path.basename(application)
readme_name = os.path.basename(readme)

# --- contents ---------------------------------------------------------------

files = [application, readme]
symlinks = {"Applications": "/Applications"}

# Volume icon, shown once the image is mounted. This is the icon that lives
# inside the image and survives any transport. Giving the .dmg *file* itself a
# custom icon would mean an extended attribute, which does not survive the zip
# GitHub Actions wraps every artifact in -- so it is not attempted.
icon = os.environ["DMG_VOLUME_ICON"]

# --- image ------------------------------------------------------------------

format = "UDZO"
size = None  # dmgbuild sizes the image from its contents

# --- window -----------------------------------------------------------------

window_rect = ((100, 100), (640, 400))
default_view = "icon-view"
icon_size = 128
text_size = 13
background = None

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_locations = {
    app_name: (160, 170),
    "Applications": (480, 170),
    readme_name: (320, 310),
}
