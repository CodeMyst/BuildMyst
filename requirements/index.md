# Requirements

This is the requirements file for this project. It defines the problem this project solves and a full example.

## Problem

The problem BuildMyst solves is being able to build a project with different configurations, having a special build process for whatever type of file, directory or any other flags you pass to it. It should also be able to watch files for changes and execute tasks according to it. When a file changes all other files don't necessarily need be built. So you can specify what some files or directories depend on, and what do those dependencies depend on.

After everything is built it can do some other tasks like copying some files from the source to the output directory, cleaning up some files, etc.

If the amount of built in options isn't enough you can make your own actions using small D scripts which will be invoked by the build system.

All the configuration will be done in a single YAML file and in additional D scripts.

## Example

This is a small example that demonstrates how it works. Here we have 2 directories: view and style. In view there are a number of PUG files which need to be compiled to HTML and in the style folder are SCSS files which need to be compiled into CSS. In the watch mode it should watch for view and style directories separately.

In the debug build it will call a D script which will go through every file and append a date on the end of the file (it should take into account the type of file and insert it as a comment, but I'll be keeping the example simple and will just insert the date plainly).

Directory structure:

```
.buildmyst/
    scripts/
        appendDates.d
    config.yaml
dist/
    views/
        index.html
    style/
        style.css
source/
    views/
        header.pug
        index.pug
    style/
        variables.scss
        style.scss
```

.config:

```yaml
---
source_dir: $source "source/"
dist_dir: $dist "dist/"

actions:
    build_views:
        - pug $source + view/index.pug -o $dist
    build_styles:
        - sass $source + style/style.scss $dist + style/style.css
    append_dates:
        - ${appendDates $dist} # this will call the appendDates.d script passing the dist directory

configurations:
    - debug
    - release

build_debug:
    - ${build_release} # to reduce copy pasting, the debug build will first run the release build. In proper projects the release build might include some extra stuff like minifying the code which you don't want in the debug build. To sole this you could have a build_basic which would be shared by both the release and debug builds.
    - append_dates

build_release:
    - build_views
    - build_styles

watch:
    $source + view/:
        - ${build_views}
    $source + style/:
        - ${build_styles}
...
```

appendDates.d:

```d
void main (string [] args)
{
    auto files = dirEntries (args [0], SpanMode.depth).filter (f => f.isFile ());

    foreach (file; files)
    {
        file.append ("\n" ~ Clock.currTime ());
    }
}
```
