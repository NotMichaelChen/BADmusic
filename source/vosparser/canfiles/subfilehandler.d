module vosparser.canfiles.subfilehandler;

import std.bitmanip;

class SubfileHandler
{
private:
    ubyte[] data;
    int ptr;

public:
    this(ubyte[] d)
    {
        data = d;
    }

    void skipBytes(int amount)
    {
        ptr += amount;
    }

    ubyte[] readBytes(int amount)
    {
        ubyte[] slice = data[ptr..ptr+amount];
        ptr += amount;
        return slice;
    }

    ubyte[] readByteString(T)()
    {
        //Read length bytes
        ubyte[T.sizeof] len = readBytes(T.sizeof);

        //Interpret and return that amount of bytes
        T size = len[0..len.length].peek!(T, Endian.littleEndian);
        return readBytes(size);
    }

    T readBytesInterpreted(T)()
    {
        return readBytes(T.sizeof).peek!(T, Endian.littleEndian);
    }

    //TODO: add "skipByteString"
}