module vosparser.canfiles.canparser;

import std.stdio, std.bitmanip, std.system, std.range, std.utf, std.exception, std.format;
import vosparser.canfiles.subfilehandler;
import vosparser.songdata;

//Parses a string of bytes. A "string" in this context means a fixed amount of "length" bytes and a variable length
//of "payload" bytes.
//T: type to hold the length bytes. Must be unsigned, or may crash from negative array allocation
//File: file to read bytes from
//return: Payload bytes
private ubyte[] parseByteString(T)(File file)
{
    //Read length bytes
    ubyte[T.sizeof] len;
    file.rawRead(len);

    //Interpret and allocate array
    T size = len[0..$].peek!(T, Endian.littleEndian);
    ubyte[] str = new ubyte[size];

    //Read and return
    file.rawRead(str);
    return str;
}

public void parseCan(File canfile)
{
    //Assumes first 4-byte header was read

    while(canfile.tell != canfile.size)
    {
        string name = cast(string)parseByteString!uint(canfile);
        ubyte[] data = parseByteString!uint(canfile);

        validate(name);

        writeln(name);
        writeln(data.length);

        if(name == "Vosctemp.trk")
            parseCanTrk(data);
        else if(name == "VOSCTEMP.mid")
            parseCanMidi(data);
        else
            throw new Exception("Invalid sub-file in canfile");
    }
}

//TODO: Add lots of safety checks
private void parseCanTrk(ubyte[] data)
{
    VosSong songdata;

    SubfileHandler subfile = new SubfileHandler(data);
    int fileversion = -1;

    //Read file version
    ubyte[] subfileversion = subfile.readBytes(6);
    if(subfileversion == [86, 79, 83, 48, 50, 50]) //VOS022
        fileversion = 22;
    else if(data[0..6] == [86, 79, 83, 48, 48, 54]) //VOS006
        fileversion = 6;

    enforce(fileversion != -1, "Unable to parse Trk subfile with unknown version");

    //Read chart metadata
    writeln("title: ", cast(string)subfile.readByteString!(ushort));
    writeln("artist: ", cast(string)subfile.readByteString!(ushort));
    writeln("comment: ", cast(string)subfile.readByteString!(ushort));
    writeln("vos_author: ", cast(string)subfile.readByteString!(ushort));
    writeln("genre?: ", cast(string)subfile.readByteString!(ushort));

    subfile.skipBytes(11);

    //Read length of chart
    uint length_tt = subfile.readBytesInterpreted!uint();
    uint length = subfile.readBytesInterpreted!uint();

    writeln("length_tt: ", length_tt);
    writeln("length: ", length);

    subfile.skipBytes(1024);

    //Read number of note arrays
    uint narr = subfile.readBytesInterpreted!uint();
    songdata.note_arrays.length = narr;
    writeln("narr: ", narr);
    subfile.skipBytes(4);

    //Read note array info
    foreach(i; 0 .. narr)
    {
        enforce(subfile.readBytes(1)[0] == 4, "note_arr_info did not contain 4 at beginning of array");
        writeln("instrument type: ", subfile.readBytesInterpreted!uint());
    }

    subfile.skipBytes(1);
    writeln("level: ", subfile.readBytesInterpreted!ubyte() + 1);
    subfile.readByteString!ushort();
    subfile.skipBytes(4);

    foreach(i; 0 .. narr)
    {
        uint nnote = subfile.readBytesInterpreted!uint();
        songdata.note_arrays[i].length = nnote;
        writeln("nnote: ", nnote);
        foreach(j; 0 .. nnote)
        {
            
            ubyte[16] raw_note = subfile.readBytes(16);
            writeln(raw_note[0..16].peek!(uint, Endian.littleEndian)(1) );
        }
    }

    if(fileversion == 22)
        subfile.skipBytes(4);
    
    uint nunote = subfile.readBytesInterpreted!uint();
    writeln("nunote (User note array): ", nunote);

    foreach(i; 0 .. nunote)
    {
        ubyte narrindex = subfile.readBytesInterpreted!ubyte();
        uint index = subfile.readBytesInterpreted!uint();
        uint key = subfile.readBytesInterpreted!ubyte();

        writefln("note: %d, narr index: %d, index: %d, key: %d", i, narrindex, index, key);
        enforce(narrindex < narr);
        enforce(key < 7);
    }

    uint somebyte = (fileversion == 22) ? subfile.readBytesInterpreted!uint() : 0;
    if(somebyte == 0)
    {
        uint nlyric = subfile.readBytesInterpreted!uint();
        writeln("Lyric array: nlyric = ", nlyric);
        foreach(_; 0 .. nlyric)
        {
            uint time = subfile.readBytesInterpreted!uint();
            ubyte[] lyric = subfile.readByteString!ushort();
            writefln("Lyric at tt=0x%x: %s", time, lyric);
        }
    }
    else
    {
        writeln("Unknown byte after nunotes: ", somebyte);
    }
}

private void parseCanMidi(ubyte[] data)
{

}

// private Note parseNote(ubyte[] notebytes)
// {
//     enforce(notebytes.length == 16, format("Note given is not of size 16, but of size %d", notebytes.length));

//     Note note;

//     //TODO: refactor parsing
//     ubyte tempbyte = notebytes.read!(ubyte, Endian.littleEndian);
//     enforce(tempbyte == 0, format("First byte in note is not zero: %d", tempbyte));
//     // uint time = parseByteString!uint();

//     ubyte note_num = notebytes.read!(ubyte, Endian.littleEndian);
//     ubyte track = notebytes.read!(ubyte, Endian.littleEndian);
//     ubyte vol = notebytes.read!(ubyte, Endian.littleEndian);
//     ubyte is_user = notebytes.read!(ubyte, Endian.littleEndian);
//     tempbyte = notebytes.read!(ubyte, Endian.littleEndian);
//     ubyte is_long = notebytes.read!(ubyte, Endian.littleEndian);
//     // len
//     tempbyte = notebytes.read!(ubyte, Endian.littleEndian);
//     enforce(tempbyte == 0 || tempbyte == 0xFF, format("Last byte in note is incorrect: %d", tempbyte));

    
// }