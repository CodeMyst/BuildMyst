import std.file;
import std.path;
import std.array;
import std.stdio;
import std.algorithm;
import std.process;
import std.conv;
import std.getopt;
import colorize;
import dyaml;

private string projectDir = "";
private const string buildMystDirName = ".buildmyst";
private const string configName = "config.yaml";

private string [] configurations;
private string [] customScripts;
private Action [] actions;
private BuildAction [] buildActions;

private string configuration;

int main (string [] args)
{
    const auto options = getopt
    (
        args,
        "targetDirectory|t", &projectDir,
        "configuration|c", &configuration
    );

    if (options.helpWanted)
    {
        cwriteln ("usage: buildmyst [options]");
        cwriteln ();
        cwriteln ("options:");
        cwriteln ("\t--targetDirectory\t[-t]\t[Optional] Runs BuildMyst in the target directory. If not specified runs in the current directory.");
        cwriteln ("\t--configuration\t\t[-c]\t[Optional] Runs the build with the specified configuration. If not specified it uses the first configuration in the config file.");

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
    }

    if (configuration == "")
    {
        configuration = configurations [0];
    }

    BuildAction buildAction = buildActions.find!(a => a.configuration == configuration) [0];
    executeBuildAction (buildAction);

    return 0;
}

private Node getConfig ()
{
    return Loader.fromFile (cast (string) (chainPath (projectDir, buildMystDirName, configName).array)).load ();
}

private Action [] getActions (Node actionsNode)
{
    Action [] actions;

    foreach (Node actionKey, Node actionValue; actionsNode)
    {
        string name = actionKey.as!string;
        string [] commands;

        foreach (Node actionCommand; actionValue)
        {
            string command = actionCommand.as!string;
            if (command.startsWith ("${") && command.endsWith ("}"))
            {
                string customScript = command [2..$].split (" ") [0];
                string [] parameters = command [3 + customScript.length..$-1].split (" ");
                writeln (parameters);
                if (customScripts.canFind (customScript) == false)
                {
                    throwError (cast (string) ("Custom script: " ~ customScript ~ " doesn't exist. Either remove the action from the config or create the script in: " ~ chainPath (projectDir, buildMystDirName, "scripts", customScript).array ~ ".d."));
                    return null;
                }
                command = customScriptToCommand (customScript, parameters);
            }
         
            commands ~= command;
        }

        actions ~= new Action (name, commands);
    }

    return actions;
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
    BuildAction buildAction = new BuildAction ();
    buildAction.name = name;
    buildAction.configuration = name [6..$];

    foreach (Node action; buildActionsNode)
    {
        string actionName = action.as!string [2..$-1];
        buildAction.actions ~= actions.find!(e => e.name == actionName) [0];
    }

    return buildAction;
}

private void executeBuildAction (BuildAction buildAction)
{
    cwrite ("Running build: ");
    cwrite (buildAction.name.color (fg.cyan).style (mode.bold));
    cwriteln ();
    cwriteln ();

    cwriteln ("Running actions: ");

    foreach (Action action; buildAction.actions)
    {
        cwrite (("\t" ~ action.name).color (fg.cyan).style (mode.bold));
        foreach (string command; action.commands)
        {
            auto process = executeShell (command, null, Config.none, size_t.max, projectDir);
            if (process.status == 0)
            {
                cwrite ("\t✓".color (fg.green).style (mode.bold));
                cwriteln ();
            }
            else
            {
                cwrite ("\t✗".color (fg.red).style (mode.bold));
                cwriteln ();
                cwriteln ();
                cwriteln (("Command: " ~ command ~ " exited with code: " ~ process.status.to!string).color (fg.red));
                cwriteln (process.output);
                cwriteln ("Build failed".color (fg.red).style (mode.bold));
                return;
            }
        }
    }

    cwriteln ("\nBuild succeeded".color (fg.green).style (mode.bold));
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
