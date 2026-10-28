# Fallback artwork

`NO-COVER.png` is the transparent vinyl record used for tracks without embedded
or server artwork. The current track, Up Next, and fzf previews all use this
same asset. It also works in random/shuffle playback.

Created with the built-in imagegen tool on 2026-10-12. The PNG is square RGBA
and keeps transparent pixels around the record; do not flatten it against a
solid background when replacing or exporting it.

Generation prompt:

> Use case: product-mockup. Asset type: square PNG fallback album artwork for a terminal music player. Create one elegant generic vinyl record, isolated on a genuinely transparent background. Strict top-down orthographic view, a perfectly circular black graphite vinyl disc centered in the square canvas with generous even 10% margins. Fine realistic concentric grooves, subtle soft silver reflections across the grooves and a gently lit outer rim so it stays readable on a dark terminal. Small warm off-white blank center label and a tiny spindle hole. Understated, refined, clean studio product illustration. No text, no lettering, no logos, no watermark, no musical notes, no sleeve, no turntable, no extra objects, no solid backdrop, no cast shadow outside the disc. Preserve actual transparency outside the record. The record should be much calmer and more polished than an oversized white musical-note icon.
