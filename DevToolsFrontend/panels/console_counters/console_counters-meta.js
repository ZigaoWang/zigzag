import*as e from"../../ui/legacy/legacy.js";var o;async function r(){return o||(o=await import("./console_counters.js")),o}e.Toolbar.registerToolbarItem({async loadItem(){return(await r()).WarningErrorCounter.WarningErrorCounter.instance()},order:1,location:e.Toolbar.ToolbarItemLocation.MAIN_TOOLBAR_RIGHT});
//# sourceMappingURL=console_counters-meta.js.map
