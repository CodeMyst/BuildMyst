void main (string [] args)
{
    import std.file : rmdirRecurse;

    rmdirRecurse (args [1]);
}
