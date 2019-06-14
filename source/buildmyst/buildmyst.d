module buildmyst.buildmyst;

import colorize;
import dyaml;

private string targetDirectory = "";

private const string buildMystDirName = ".buildmyst";
private const string buildMystConfigName = "config.yaml";
private const string customScriptsDirName = "scripts";

private string [] configurations;
private string configuration;

private bool shouldWatch;

private string [] customScripts;
private Action [] actions;
private BuildAction [] buildActions;
private BuildAction beforeBuild;
private BuildAction afterBuild;
private WatchAction [] watchActions;

private class Action
{
    public string name;
    public string [] commands;
}

private class BuildAction
{
    public string name;
    public string configuration;
    public Action [] actions;
    public bool isEvent;
}

private class WatchAction
{
    public string path;
    public Action [] actions;
}

/++
 + Runs the pgoram.
 +/
public int run (string [] args)
{
    import std.getopt : getopt, GetoptResult;
    import std.file : exists;
    import std.algorithm : find;

    const GetoptResult options = getopt
    (
        args,
        "targetDirectory|t", &targetDirectory,
        "configuration|c", &configuration,
        "watch|w", &shouldWatch
    );

    if (options.helpWanted)
    {
        printHelp ();
        return 0;
    }

    if (!exists (getBuildMystDir ()))
    {
        throwError ("Missing " ~ buildMystDirName ~ " directory." ~
                    " You can specify one with the -t option. Run buildmyst -h for more information.");
        return 1;
    }

    if (!exists (getBuildMystConfigFile ()))
    {
        throwError ("Missing " ~ getBuildMystConfigFile ()  ~ " config file.");
        return 1;
    }

    getCustomScripts ();

    parseConfig ();

    if (!shouldWatch)
    {
        if (configuration == "")
        {
            configuration = configurations [0];
        }

        if (beforeBuild !is null)
        {
            if (!executeBuildAction (beforeBuild))
            {
                cwriteln ("Build failed".color (fg.red).style (mode.bold));
                return 1;
            }

            cwriteln ();
        }

        BuildAction buildAction = buildActions.find! (e => e.configuration == configuration) [0];
        if (!executeBuildAction (buildAction))
        {
            cwriteln ("Build failed".color (fg.red).style (mode.bold));
            return 1;
        }

        if (afterBuild !is null)
        {
            cwriteln ();
            if (!executeBuildAction (afterBuild))
            {
                cwriteln ("Build failed".color (fg.red).style (mode.bold));
                return 1;
            }
        }

        cwriteln ();
        cwriteln ("Build passed".color (fg.green).style (mode.bold));
    }
    else
    {
        watch ();
    }

    return 0;
}

unittest
{
    import std.file : exists, readText;

    assert (run (["buildmyst", "-t", "test/", "-c", "test"]) == 0);
    assert (exists ("test/dist/"));
    assert (exists ("test/dist/test.txt"));
    assert (readText ("test/dist/test.txt") == "123\n");
}

private void watch ()
{
    import fswatch : FileWatch, FileChangeEvent, FileChangeEventType;
    import std.path : dirName;
    import std.utf : UTFException;

    clearScreen ();

    cwriteln ("Watching...".color (fg.light_magenta).style (mode.bold));

    FileWatch watcher = FileWatch (targetDirectory == "" ? "." : targetDirectory, true);
    while (true)
    {
        FileChangeEvent [] events;

        try
        {
            events = watcher.getEvents ();
        }
        // Sometimes fswatch throws a UTFException when a file name contains invalid characters
        catch (UTFException)
        {
            continue;
        }

        foreach (FileChangeEvent event; events)
        {
            foreach (WatchAction watchAction; watchActions)
            {
                // Check if event path is relative to watchAction.path
                string eventPath = dirName (event.path);

                if (eventPath.length > watchAction.path.length &&
                    eventPath [0..watchAction.path.length] == watchAction.path &&
                    event.type == FileChangeEventType.modify)
                {
                    clearScreen ();
                    cwriteln ("Watching...".color (fg.light_magenta).style (mode.bold));
                    cwriteln ();
                    cwrite (watchAction.path.color (fg.light_magenta));
                    cwriteln (" changed");
                    cwriteln ();

                    bool buildPassed = true;

                    foreach (Action action; watchAction.actions)
                    {
                        if (!executeAction (action))
                        {
                            buildPassed = false;
                        }
                    }

                    cwriteln ();

                    if (buildPassed)
                    {
                        cwriteln ("Build passed".color (fg.green).style (mode.bold));
                    }
                    else
                    {
                        cwriteln ("Build failed".color (fg.red).style (mode.bold));
                    }
                }
            }
        }
    }
}

private bool executeBuildAction (BuildAction buildAction)
{
    cwrite (buildAction.name.color (fg.light_magenta).style (mode.bold));
    cwriteln ();
    cwriteln ();

    foreach (Action action; buildAction.actions)
    {
        if (!executeAction (action))
        {
            return false;
        }
    }

    return true;
}

private bool executeAction (Action action)
{
    import std.process : executeShell, Config;
    import std.conv : to;

    cwritef ("\t%-50s", (action.name).color (fg.cyan).style (mode.bold));
    foreach (string command; action.commands)
    {
        auto process = executeShell (command, null, Config.none, size_t.max, targetDirectory);
        if (process.status != 0)
        {
            cwrite ("✗".color (fg.red).style (mode.bold));
            cwriteln ();
            cwriteln ();
            cwriteln (("Command: " ~ command ~ " exited with code: " ~ process.status.to!string).color (fg.red));
            cwriteln (process.output);
            return false;
        }
    }

    cwrite ("✓".color (fg.green).style (mode.bold));
    cwriteln ();

    return true;
}

private void getCustomScripts ()
{
    import std.file : dirEntries, SpanMode, isFile;
    import std.algorithm : filter;
    import std.path : absolutePath, relativePath, stripExtension;

    string customScriptsDir = getCustomScriptsDir ();

    auto scripts = dirEntries (customScriptsDir, SpanMode.depth).filter!(f => f.isFile ());
    string base = absolutePath (customScriptsDir);

    string [] res;

    foreach (script; scripts)
    {
        res ~= relativePath (script.name.absolutePath (), base).stripExtension ();
    }

    customScripts = res;
}

private void parseConfig ()
{
    import std.algorithm : startsWith;

    Node config = Loader.fromFile (cast (string) getBuildMystConfigFile ()).load ();

    foreach (Node key, Node value; config)
    {
        string keyName = key.as!string;

        if (keyName == "actions")
        {
            actions = parseActions (value);
        }
        else if (keyName == "configurations")
        {
            configurations = parseConfigurations (value);
        }
        else if (keyName.startsWith ("build"))
        {
            buildActions ~= parseBuildAction (keyName, value);
        }
        else if (keyName == "before_build")
        {
            beforeBuild = parseBuildAction (keyName, value, true);
        }
        else if (keyName == "after_build")
        {
            afterBuild = parseBuildAction (keyName, value, true);
        }
        else if (keyName == "watch")
        {
            if (shouldWatch)
            {
                watchActions = parseWatchActions (value);
            }
        }
        else
        {
            throwWarning ("Unknown key: " ~ keyName ~ ". Ignoring.");
        }
    }
}

private Action [] parseActions (Node value)
{
    Action [] res;

    foreach (Node actionKey, Node actionValue; value)
    {
        Action a = new Action ();
        a.name = actionKey.as!string;
        a.commands = parseCommands (actionValue);
        res ~= a;
    }

    return res;
}

private WatchAction [] parseWatchActions (Node value)
{
    import std.algorithm : find;
    import std.string : chomp;
    import std.path : dirSeparator;

    WatchAction [] res;

    foreach (Node watchKey, Node watchActions; value)
    {
        string path = watchKey.as!string;
        path = path.chomp (dirSeparator);
        Action [] a;

        foreach (Node action; watchActions)
        {
            string actionName = action.as!string [2..$-1];
            a ~= actions.find! (e => e.name == actionName) [0];
        }

        WatchAction wa = new WatchAction ();
        wa.path = path;
        wa.actions = a;
        res ~= wa;
    }

    return res;
}

private string [] parseConfigurations (Node value)
{
    string [] res;

    foreach (string conf; value)
    {
        res ~= conf;
    }

    return res;
}

private BuildAction parseBuildAction (string name, Node value, bool isEvent = false)
{
    import std.algorithm : canFind, find;

    BuildAction res = new BuildAction ();
    res.isEvent = isEvent;
    res.name = name;

    if (!isEvent)
    {
        string configurationName = name [6..$];

        if (configurations.canFind (configurationName) == false)
        {
            throwWarning ("Configuration: " ~ configurationName ~
                          " doesn't exist. Ignoring " ~ name ~ " build action.");
            return null;
        }

        res.configuration = configurationName;
    }

    foreach (Node action; value)
    {
        string actionName = action.as!string [2..$-1];
        res.actions ~= actions.find! (e => e.name == actionName) [0];
    }

    return res;
}

private string [] parseCommands (Node value)
{
    import std.algorithm : startsWith, endsWith, canFind;
    import std.array : split, array;
    import std.path : chainPath;

    string [] res;

    foreach (Node commandNode; value)
    {
        string command = commandNode.as!string;

        if (command.startsWith ("${") && command.endsWith ("}"))
        {
            string [] customScriptArgs = command [2..$-1].split (" ");
            string customScriptName = customScriptArgs [0];
            string [] customScriptParameters = customScriptArgs [1..$];

            if (!customScripts.canFind (customScriptName))
            {
                throwError (cast (string) ("Custom script: " ~ customScriptName ~ " doesn't exist." ~
                            "Either remove the action from the config or create the script in: " ~
                            chainPath (getCustomScriptsDir (), customScriptName).array ~ ".d."));
                return null;
            }

            command = parseCustomScript (customScriptName, customScriptParameters);
        }

        res ~= command;
    }

    return res;
}

private string parseCustomScript (string customScriptName, string [] parameters)
{
    import std.path : chainPath;
    import std.array : array, join;

    string scriptPath = cast (string) chainPath (buildMystDirName, customScriptsDirName, customScriptName).array ~
                        ".d" ~
                        " " ~
                        parameters.join (" ");

    return "rdmd " ~ scriptPath;
}

private void printHelp ()
{
    cwriteln ("Usage: buildmyst [options]");
    cwriteln ();
    cwriteln ("Options:");
    cwriteln ("        --targetDirectory    [-t]" ~
              "        [Optional]" ~
              " Runs BuildMyst in the target directory. If not specified runs in the current directory.");
    cwriteln ("        --configuration      [-c]" ~
              "        [Optional]" ~
              " Runs the build with the specified configuration." ~
              " If not specified it uses the first configuration in the config file.");
    cwriteln ("        --watch              [-w]" ~
              "        [Optional]" ~
              " Runs BuildMyst in the watch mode.");
}

private string getBuildMystDir ()
{
    import std.path : chainPath;
    import std.array : array;

    return chainPath (targetDirectory, buildMystDirName).array;
}

private string getBuildMystConfigFile ()
{
    import std.path : chainPath;
    import std.array : array;

    return chainPath (targetDirectory, buildMystDirName, buildMystConfigName).array;
}

private string getCustomScriptsDir ()
{
    import std.path : chainPath;
    import std.array : array;

    return chainPath (targetDirectory, buildMystDirName, customScriptsDirName).array;
}

private void throwError (string msg)
{
    cwrite (" ERROR ".color (fg.black, bg.red));
    cwrite ((" " ~ msg).color (fg.red).style (mode.bold));
    cwriteln ();
}

private void throwWarning (string msg)
{
    cwrite (" WARNING ".color (fg.black, bg.light_yellow));
    cwrite ((" " ~ msg).color (fg.light_yellow).style (mode.bold));
    cwriteln ();
}

private void clearScreen ()
{
    cwritef ("\033[1;1H\033[2J");
}

