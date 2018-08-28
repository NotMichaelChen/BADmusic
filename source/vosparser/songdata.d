module vosparser.songdata;

//"Notes" refer to some entity that produces a sound. Some of these notes are playable - the rest are BGM
//"User Notes" refer to the playable notes

struct Note
{
    double tt_start, tt_end;
    double rt_start, rt_end;
    uint cmd, note_num, vol;
    bool is_user, is_long;
}

struct UserNote
{
    double rt_start; /* Time of the Note-on event in seconds from the start of the song */
    double tt_start; /* Time of the Note-on event in MIDI quarter-notes from the start of the song */
    double rt_stop, tt_stop; /* For long notes, it is {rt,tt}_end; for short notes, it is {rt,tt}_start.
                    Used when displaying notes and scoring. */
    double rt_end, tt_end; /* Time of the corresponding Note-off event.  Used when playing short notes. */
    ubyte cmd, note_num, vol; /* Corresponding MIDI command */
    uint key, color; /* Key is 0-6 for do,re,mi,fa,so,la,ti; Color is 0-15 */
    bool is_long;
    uint prev_idx, next_idx; /* The array index of the previous/next note on the same key;
                    IDX_NONE if there is none */
    uint prev_idx_long, next_idx_long;
    uint count, count_long; /* The number of (long) notes on this key, including this one */
}

struct VosSong
{
    Note[][] note_arrays;
    UserNote[] user_notes;
}