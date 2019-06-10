import std.file;
import std.path;
import std.array;
import std.stdio;
import std.algorithm;
import std.process;
import std.conv;
import std.getopt;
import colorize;
import fswatch;
import dyaml;

private string projectDir = "";
private const string buildMystDirName = ".buildmyst";
private const string configName = "config.yaml";

private string [] configurations;
private string [] customScripts;
private Action [] actions;
private BuildAction [] buildActions;
private BuildAction beforeBuild;
private BuildAction afterBuild;
private Watcher [] watchers;

private string configuration;

private bool shouldWatch;

int mainz (string [] args)
{
    const auto options = getopt
    (
        args,
        "targetDirectory|t", &projectDir,
        "configuration|c", &configuration,
        "watch|w", &shouldWatch
    );

    if (options.helpWanted)
    {
        cwriteln ("Usage: buildmyst [options]");
        cwriteln ();
        cwriteln ("Options:");
        cwriteln ("\t--targetDirectory\t[-t]\t[Optional] Runs BuildMyst in the target directory. If not specified runs in the current directory.");
        cwriteln ("\t--configuration\t\t[-c]\t[Optional] Runs the build with the specified configuration. If not specified it uses the first configuration in the config file.");
        cwriteln ("\t--watch\t\t\t[-w]\t[Optional] Runs BuildMyst in the watch mode.");

        return 0;
    }

    if (!exists (chainPath (projectDir, buildMystDirName)))
    {
        throwError ("Missing " ~ buildMystDirName ~ " directory. You can specify one with the -t option. Run buildmyst -h for more information.");
        return 1;
    }

    if (!exists (chainPath (projectDir, buildMystDirName, configName)))
    {
        throwError ("Missing " ~ configName ~ " file.");
        return 1;
    }

    customScripts = getCustomScripts ();

    Node config = getConfig ();

    foreach (Node key, Node value; config)
    {
        if (key.as!string == "actions")
        {
            actions = getActions (value);
            if (actions == null)
            {
                return 1;
            }
        }
        else if (key.as!string == "configurations")
        {
            configurations = getConfigurations (value);
        }
        else if (key.as!string.startsWith ("build"))
        {
            string buildName = key.as!string;

            string buildConfiguration = buildName [6..$];

            if (configurations.canFind (buildConfiguration) == false)
            {
                throwWarning ("Configuration: " ~ buildConfiguration ~ " doesn't exist. Ignoring " ~ buildName ~ " build action.");
            }
            else
            {
                buildActions ~= getBuildAction (actions, buildName, value);
            }
        }
        else if (key.as!string == "before_build")
        {
            beforeBuild = getBuildEvent (actions, key.as!string, value);
        }
        else if (key.as!string == "after_build")
        {
            afterBuild = getBuildEvent (actions, key.as!string, value);
        }
        else if (key.as!string == "watch")
        {
            if (shouldWatch)
            {
                watchers = getWatchers (actions, value);
            }
        }
        else
        {
            throwWarning ("Unknown key: " ~ key.as!string ~ ". Ignoring.");
        }
    }

    if (shouldWatch == false)
    {
        if (configuration == "")
        {
            configuration = configurations [0];
        }

        bool ok = true;

        if (beforeBuild !is null)
        {
            if (executeBuildAction (beforeBuild) == false)
            {
                cwriteln ("Build failed".color (fg.red).style (mode.bold));
                return 1;
            }

            cwriteln ();
        }

        BuildAction buildAction = buildActions.find!(a => a.configuration == configuration) [0];
        if (executeBuildAction (buildAction) == false)
        {
            cwriteln ("Build failed".color (fg.red).style (mode.bold));
            return 1;
        }

        if (afterBuild !is null)
        {
            cwriteln ();
            if (executeBuildAction (afterBuild) == false)
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
        cwriteln ("Watching...".color (fg.light_magenta).style (mode.bold));
        string watchPath = projectDir == "" ? "." : projectDir;
        FileWatch fileWatcher = FileWatch (watchPath, true);

        while (true)
        {
            FileChangeEvent [] events = fileWatcher.getEvents ();

            foreach (FileChangeEvent event; events)
            {
                foreach (Watcher watcher; watchers)
                {
                    // TODO: the dir separator is different on other OS
                    const string watcherPath = watcher.path [$-1] == '/' ? watcher.path [0..$-1] : watcher.path;
                    if (dirName (event.path) == watcherPath)
                    {
                        cwriteln ();
                        cwrite (watcher.path.color (fg.light_magenta));
                        cwriteln (" changed...");
                        cwriteln ();

                        foreach (Action action; watcher.actions)
                        {
                            cwritef ("%-50s", (action.name).color (fg.cyan).style (mode.bold));
                            foreach (string command; action.commands)
                            {
                                auto process = executeShell (command, null, Config.none, size_t.max, projectDir);
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
                        }
                    }
                }
            }
        }
    }

    return 0;
}

private Node getConfig ()
{
    return Loader.fromFile (cast (string) (chainPath (projectDir, buildMystDirName, configName).array)).load ();
}

private Action [] getActions (Node actionsNode)
{
    Action [] res;

    foreach (Node actionKey, Node actionValue; actionsNode)
    {
        string name = actionKey.as!string;
        string [] commands = commandsToAction (actionValue);

        res ~= new Action (name, commands);
    }

    return res;
}

private string [] commandsToAction (Node action)
{
    string [] commands;

    foreach (Node actionCommand; action)
    {
        string command = actionCommand.as!string;
        if (command.startsWith ("${") && command.endsWith ("}"))
        {
            string customScript = command [2..$].split (" ") [0];
            string [] parameters = command [3 + customScript.length..$-1].split (" ");
            if (customScripts.canFind (customScript) == false)
            {
                throwError (cast (string) ("Custom script: " ~ customScript ~ " doesn't exist. Either remove the action from the config or create the script in: " ~ chainPath (projectDir, buildMystDirName, "scripts", customScript).array ~ ".d."));
                return null;
            }
            command = customScriptToCommand (customScript, parameters);
        }
        
        commands ~= command;
    }

    return commands;
}

private string [] getConfigurations (Node configurationsNode)
{
    string [] res;

    foreach (string configuration; configurationsNode)
    {
        res ~= configuration;
    }

    return res;
}

private string customScriptToCommand (string script, string [] parameters)
{
    string scriptPath = cast (string) (chainPath (buildMystDirName, "scripts", script).array ~ ".d" ~ " " ~ parameters.join (" "));

    return "rdmd " ~ scriptPath;
}

private string [] getCustomScripts ()
{
    auto scripts = dirEntries (chainPath (projectDir, buildMystDirName, "scripts").array, SpanMode.depth).filter! (f => f.isFile ());
    string base = absolutePath (chainPath (projectDir, buildMystDirName, "scripts").array);

    string [] res;

    foreach (script; scripts)
    {
        res ~= relativePath (script.name.absolutePath (), base).stripExtension ();
    }

    return res;
}

private BuildAction getBuildAction (Action [] actions, string name, Node buildActionsNode)
{
    BuildAction buildAction = getBuildEvent (actions, name, buildActionsNode);
    buildAction.configuration = name [6..$];

    return buildAction;
}

private BuildAction getBuildEvent (Action [] actions, string name, Node buildEventNode)
{
    BuildAction buildAction = new BuildAction ();
    buildAction.name = name;

    foreach (Node action; buildEventNode)
    {
        string actionName = action.as!string [2..$-1];
        buildAction.actions ~= actions.find!(e => e.name == actionName) [0];
    }

    return buildAction;
}

private Watcher [] getWatchers (Action [] actions, Node watchNode)
{
    Watcher [] res;

    foreach (Node watchKey, Node watchActions; watchNode)
    {
        string path = watchKey.as!string;
        Action [] a;

        foreach (Node action; watchActions)
        {
            string actionName = action.as!string [2..$-1];
            a ~= actions.find!(e => e.name == actionName) [0];
        }

        res ~= new Watcher (path, a);
    }

    return res;
}

private bool executeBuildAction (BuildAction buildAction)
{
    cwrite (buildAction.name.color (fg.light_magenta).style (mode.bold));
    cwriteln ();
    cwriteln ();

    foreach (Action action; buildAction.actions)
    {
        cwritef ("%-50s", (action.name).color (fg.cyan).style (mode.bold));
        foreach (string command; action.commands)
        {
            auto process = executeShell (command, null, Config.none, size_t.max, projectDir);
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
    }

    return true;
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

private class Action
{
    public string name;
    public string [] commands;

    public this (string name, string [] commands)
    {
        this.name = name;
        this.commands = commands;
    }
}

private class BuildAction
{
    public string name;
    public string configuration;
    public Action [] actions;

    public this ()
    {

    }

    public this (string name, Action [] actions)
    {
        this.name = name;
        this.actions = actions;
    }
} 

private class Watcher
{
    public string path;
    public Action [] actions;

    public this ()
    {

    }

    public this (string path, Action [] actions)
    {
        this.path = path;
        this.actions = actions;
    }
}
