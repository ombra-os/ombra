// Ombra default Plasma layout: information in the top bar, apps in the
// floating bottom dock. plasma-shell runs this ONCE on first login (the
// filename is exact — any other name silently falls back to the stock
// single panel). Panel API per plasma-workspace 6.3.6.

var bar = new Panel
bar.location = "top"
bar.floating = false
bar.hiding = "none"
// panel glass comes from the desktoptheme's panel-background.svg alpha;
// PanelView reads panelOpacity from plasmashellrc [PlasmaViews], never
// from the containment config, and Colloid-dark has no adaptive
// transparency, so the effective mode is Translucent regardless
bar.lengthMode = "fill"
bar.height = Math.floor(gridUnit * 2)

bar.addWidget("org.ombra.status")
// app menus live in the bar, macOS-style: Qt apps export automatically
// once this widget exists (kded appmenu publishes the Registrar); kitty
// and systemsettings have no menus and collapse to zero width
bar.addWidget("org.kde.plasma.appmenu")
bar.addWidget("org.kde.plasma.panelspacer")

// org.kde.plasma.systemtray, NOT the private one: the private applet
// crashes plasmashell mid-script when added this way, and the restart
// then skips the rest of the layout
bar.addWidget("org.kde.plasma.systemtray")

var clock = bar.addWidget("org.kde.plasma.digitalclock")
clock.currentConfigGroup = ["Appearance"]
clock.writeConfig("showDate", true)
clock.writeConfig("dateDisplayFormat", 1)
clock.writeConfig("dateFormat", "custom")
clock.writeConfig("customDateFormat", "ddd MMM d")
clock.writeConfig("use24hFormat", 0)
// smaller than the panel-auto size, deliberately quiet in the corner
clock.writeConfig("autoFontAndSize", false)
clock.writeConfig("fontSize", 9)

var dock = new Panel
dock.location = "bottom"
dock.floating = true
dock.hiding = "none"
dock.alignment = "center"
dock.lengthMode = "fit"
dock.height = 2 * Math.floor(gridUnit * 2.5 / 2)

dock.addWidget("org.kde.plasma.kickoff")

// launcher ids MUST be real desktop-file basenames, and the ARRAY form
// is load-bearing: a comma-joined string value reaches icontasks as one
// merged id and renders as a single broken-launcher "?" tile
var tasks = dock.addWidget("org.kde.plasma.icontasks")
tasks.currentConfigGroup = ["General"]
tasks.writeConfig("launchers", ["applications:org.kde.dolphin.desktop", "applications:kitty.desktop", "applications:org.keepassxc.KeePassXC.desktop", "applications:tor-browser.desktop"])

var desktopsArray = desktopsForActivity(currentActivity());
for (var j = 0; j < desktopsArray.length; j++) {
    desktopsArray[j].wallpaperPlugin = "org.kde.image";
    desktopsArray[j].currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
    desktopsArray[j].writeConfig("Image", "/usr/share/backgrounds/ombra/ombra-02-4k.png");
}
