-- Finder stores a disk image's presentation in .DS_Store. Keeping this tiny
-- script as source makes the visual contract inspectable instead of requiring
-- a developer to reproduce it by hand before every release.
on run arguments
    set mountPath to item 1 of arguments
    set mountedFolder to POSIX file mountPath as alias

    tell application "Finder"
        set targetDisk to disk of mountedFolder
        tell targetDisk
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set pathbar visible of container window to false
            set sidebar width of container window to 0
            -- Finder counts the 28-point title bar in `bounds`; the background
            -- covers only the content area. 660 x 468 therefore exposes the
            -- complete 660 x 440 image without a cropped lower edge.
            set bounds of container window to {120, 120, 780, 588}

            set viewOptions to icon view options of container window
            set icon size of viewOptions to 112
            set text size of viewOptions to 13
            set shows icon preview of viewOptions to true
            set shows item info of viewOptions to false
            set background picture of viewOptions to file ".background:background.jpg"

            -- The native Applications folder draws roughly fourteen points
            -- wider than the square app icon, while the background's lower
            -- visual axis is near x=340. These are optical, not arithmetic,
            -- centers: the rendered silhouettes balance around that axis.
            set position of item "xsComic.app" to {175, 220}
            set position of item "Applications" to {499, 220}
            set position of item "Licenses" to {342, 355}
            update without registering applications
            delay 2
            close
        end tell
    end tell
end run
