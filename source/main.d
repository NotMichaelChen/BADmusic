import std.stdio;
import vosparser.parser, vosparser.parse, game.mainloop;

void main(string[] args)
{
	if(args.length == 1)
	{
		// File vosfile = File("./bin/1.vos", "r");
		// parseFile(vosfile);
		VosSong* song = read_vos_file("./bin/1.vos\0", 1.0);
	}
	else if(args.length == 2)
	{
		File vosfile = File(args[1], "r");
		parseFile(vosfile);
	}
	readln();

	// gameLoop();
}
