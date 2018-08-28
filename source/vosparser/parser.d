module vosparser.parser;

import std.stdio, std.bitmanip, std.system, std.range, std.utf, std.exception, std.string;
import vosparser.canfiles.canparser;

//Format derived from here https://github.com/felixonmars/pmgmusic/blob/master/format.txt

//Reads 4-byte header and determines what kind of vos file to parse as
public void parseFile(File file)
{
    ubyte[] header = new ubyte[4];
    file.rawRead(header);

    uint headernum = header.peek!(uint, Endian.littleEndian);

    switch(headernum)
    {
        case 2:
            parseCan(file);
            break;
        case 3:
            writeln("Cannot parse VOS yet!"); //TODO: implement VOS parsing
            break;
        default:
            throw new Exception(format("Invalid file header: %d",  headernum));
    }
}