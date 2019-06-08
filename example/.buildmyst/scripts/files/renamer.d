void main (string [] args)
{
    import std.file : dirEntries, SpanMode, rename;
    import std.path : stripExtension;
    import std.string : indexOf;
    import std.algorithm : filter;
    import std.datetime : Clock;

    auto files = dirEntries (args [1], SpanMode.depth).filter! (f => f.isFile ());

    foreach (file; files)
    {
        string filename = file.name [0..file.name.indexOf ('.')];
        string extension = file.name [file.name.indexOf ('.')..$];
        filename ~= "RENAMED";
        file.name.rename (filename ~ extension);
    }
}
