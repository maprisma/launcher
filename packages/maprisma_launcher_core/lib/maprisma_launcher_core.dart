/// App Manager's core.
library;

export 'package:maprisma_core_kit/ai.dart'
    show
        CatalogHelper,
        HelpersCatalog,
        argvPromptMax,
        catalogAskArgv,
        findHelperCommand,
        helperPrompt,
        helpersCatalog,
        helpersCatalogMax,
        miseShims,
        parseHelpersCatalog,
        pickHelpersCatalog,
        plainHelperName,
        shippedHelpersCatalog,
        shippedHelpersJson,
        systemHelpersCatalog,
        systemHelpersPath;
export 'package:maprisma_core_kit/process.dart';

export 'src/apps.dart';
export 'src/appimages.dart';
export 'src/cli_tools.dart';
export 'src/desktop_entries.dart';
export 'src/hypr_session.dart';
export 'src/posix.dart';
export 'src/protocol.dart';
export 'src/shlex.dart';
export 'src/core.dart';
export 'src/desktops.dart';
export 'src/icon_theme.dart';
export 'src/launch.dart';
export 'src/config.dart';
export 'src/origins.dart';
export 'src/wide_layout.dart';
export 'src/newapps.dart';
export 'src/running.dart';
export 'src/updates.dart';
export 'src/facts.dart';
export 'src/packages.dart';
export 'src/ask_ai.dart';
export 'src/ai_choice.dart';
export 'src/icons.dart' hide aliases, host;
export 'src/hyprland.dart';
export 'src/plugins.dart';
export 'src/admin.dart';
export 'src/tray.dart';
export 'src/pty.dart';
export 'src/dock.dart';
export 'src/shortcuts.dart';
export 'src/shortcuts_hypr.dart';
export 'src/shortcut_service.dart';
export 'src/screenshot.dart';

export 'src/ask_ai_rules.dart';
export 'src/mcp.dart';
