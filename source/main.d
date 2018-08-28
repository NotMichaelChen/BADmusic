import std.stdio;
import vosparser.parser, game.mainloop;

void main(string[] args)
{
	if(args.length == 1)
	{
		File vosfile = File("./bin/1.vos", "r");
		parseFile(vosfile);
	}
	else if(args.length == 2)
	{
		File vosfile = File(args[1], "r");
		parseFile(vosfile);
	}
	readln();

	// gameLoop();
}
