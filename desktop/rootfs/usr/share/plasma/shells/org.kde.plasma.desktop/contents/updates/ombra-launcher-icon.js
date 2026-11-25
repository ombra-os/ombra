// Ombra: put the Ombra mark on the dock's application-launcher button for
// users whose panel predates it (new users get it from the look-and-feel
// layout). plasmashell runs each script here once per user at its next
// start and records it in plasmashellrc [Updates] performed=. A launcher
// icon the user chose themselves is left alone.
panels().forEach(function (panel) {
    panel.widgets("org.kde.plasma.kickoff").forEach(function (launcher) {
        launcher.currentConfigGroup = ["General"];
        var icon = launcher.readConfig("icon", "");
        if (icon === "" || icon === "start-here-kde-symbolic" || icon === "start-here-kde") {
            launcher.writeConfig("icon", "ombra-launcher");
            launcher.reloadConfig();
        }
    });
});
