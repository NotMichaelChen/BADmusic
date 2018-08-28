module game.mainloop;

import gfm.sdl2;

void gameLoop()
{
    SDL2 sdl2 = new SDL2(null);
    SDLTTF sdlttf = new SDLTTF(sdl2);

    const windowFlags = SDL_WINDOW_SHOWN | SDL_WINDOW_INPUT_FOCUS | SDL_WINDOW_MOUSE_FOCUS;
    SDL2Window window = new SDL2Window(sdl2, SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, 800, 600,
        windowFlags);
    
    SDL2Renderer renderer = new SDL2Renderer(window, SDL_RENDERER_ACCELERATED); // SDL_RENDERER_SOFTWARE

    // Load the font.
    import std.file: thisExePath;
    import std.path: buildPath, dirName;
    SDLFont font = new SDLFont(sdlttf, thisExePath.dirName.buildPath("DroidSans.ttf"), 20);

    loop: while(true)
    {
        SDL_Event event;
        while(SDL_PollEvent(&event))
        {
            if(event.type == SDL_QUIT)
                break loop;
        }

        // Fill the entire screen with black (background) color.
        renderer.setColor(0, 0, 0, 0);
        renderer.clear();

        // Show the drawn result on the screen (swap front/back buffers)
        renderer.present();
    }
    //TODO: clean-up SDL correctly
}