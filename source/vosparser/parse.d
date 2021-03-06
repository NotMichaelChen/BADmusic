module vosparser.parse;

//A translation of the parser from https://github.com/felixonmars/pmgmusic

//TODO: remove all C dependencies
import core.stdc.stdio, core.stdc.stdlib, core.stdc.string;

import std.stdio, std.exception, std.digest.sha, std.conv, std.algorithm.mutation, std.algorithm.sorting;
import std.algorithm.comparison, std.format, std.bitmanip, std.system, std.math;

enum NKEY = 7;
enum SHA_DIGEST_LENGTH = 20;
enum IDX_NONE = uint.max;

struct TempoChange
{
  double rt0, tt0; /* rt and tt at the time when the tempo change occurs */
  double qn_time; /* The duration of a MIDI quarter-note after that */
}

struct MidiEvent {
  double tt;
  ubyte cmd, a, b; /* cmd is the status byte */
}

/* Stores the MIDI initialization events in an MIDI track */
struct MidiTrack
{
  uint nevent;
  MidiEvent *events;
}

/* Both BGM notes and notes played by the user */
struct Note
{
  double tt_start, tt_end;
  double rt_start, rt_end;
  uint cmd, note_num, vol;
  bool is_user, is_long;
}

struct NoteArray
{
  uint num_note;
  Note *notes;
}

/* An iterator in the TempoChange array, used to accelerate the converstion between rt's and tt's. */
struct TempoIt
{
  uint idx; /* The index of the current TempoChange being used */
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
  uint ntempo;
  TempoChange *tempos; /* The first TempoChange is the default one with qn_time=0.5 (120BPM) */
  double midi_unit_tt; /* The number of quarter-notes in a MIDI delta-time unit */
  uint ntrack;
  MidiTrack *tracks;
  uint num_note_array; /* Excluding the last one containing user notes */
  NoteArray *note_arrays;
  uint num_user_note;
  UserNote *user_notes;
  bool has_min_max_rt;
  double min_rt, max_rt; /* For now, they only count the notes, not the tracks */
  uint[NKEY] first_un_idxs; /* The first user note on each key */
  uint[NKEY] first_un_idxs_long; /* The first long user note */
  ubyte[SHA_DIGEST_LENGTH] hash;
}

//Hashes a file using SHA1.
//The FILE struct is not guaranteed to be pointing to any specific location upon completion
private void hash_file(FILE* file, ubyte* hash)
    in(file != null)
{
    ubyte* source;

    fseek(file, 0, SEEK_END);
    uint bufsize = ftell(file);
    source = cast(ubyte*) malloc(ubyte.sizeof * (bufsize + 1));
    scope(exit) free(source);

    fseek(file, 0, SEEK_SET);
    size_t readLen = fread(source, ubyte.sizeof, bufsize, file);
    enforce(readLen == bufsize);

    source[readLen] = '\0';

    string fileString = to!string(source);
    ubyte[] filehash = new ubyte[20];
    copy(sha1Of(fileString), filehash);
    
    hash = &filehash[0];
}

static double tempoit_tt_to_rt(VosSong *song, TempoIt *it, double tt)
{
  TempoChange *tc;
  
  while (it.idx > 0 && tt < song.tempos[it.idx].tt0) it.idx--;
  while (it.idx + 1 < song.ntempo && tt >= song.tempos[it.idx+1].tt0) it.idx++;
  tc = &song.tempos[it.idx];
  return tc.rt0 + (tt - tc.tt0) * tc.qn_time;
}

static double tempoit_rt_to_tt(VosSong *song, TempoIt *it, double rt)
{
  TempoChange *tc;

  while (it.idx > 0 && rt < song.tempos[it.idx].rt0) it.idx--;
  while (it.idx + 1 < song.ntempo && rt >= song.tempos[it.idx+1].rt0) it.idx++;
  tc = &song.tempos[it.idx];
  return tc.tt0 + (rt - tc.rt0) / tc.qn_time;
}

private ubyte midi_read_u8(FILE *file)
{
  int result = getc(file);
  enforce(result != EOF);
  return cast(ubyte) result;
}

private ushort midi_read_u16(FILE *file)
{
  ushort tmp;
  int result;

  result = fread(&tmp, 2, 1, file); enforce(result == 1);
  if(std.system.endian == Endian.littleEndian)
    //Split as a Big Endian number, then interpret those big endian bytes as a little endian
    return peek!(ushort, Endian.littleEndian)(nativeToBigEndian(tmp)[0..$]);
  else
    return tmp;
}

private uint midi_read_u32(FILE *file)
{
  uint tmp;
  int result;

  result = fread(&tmp, 4, 1, file); enforce(result == 1);
  if(std.system.endian == Endian.littleEndian)
    //Split as a Big Endian number, then interpret those big endian bytes as a little endian
    return peek!(uint, Endian.littleEndian)(nativeToBigEndian(tmp)[0..$]);
  else
    return tmp;
}

private uint midi_read_vl(FILE *file)
{
  int result;
  uint x = 0;

  while (1) {
    result = getc(file); enforce(result != EOF);
    x |= (result & 0x7f);
    if (result & 0x80) x <<= 7;
    else break;
  }
  return x;
}

private int tempo_change_compare(TempoChange* pa, TempoChange* pb)
// private int tempo_change_compare(gconstpointer pa, gconstpointer pb)
{
  // const TempoChange *a = cast(const TempoChange *) pa, b = cast(const TempoChange *) pb;
  // return (a.tt0 > b.tt0) - (a.tt0 < b.tt0);

  return (pa.tt0 > pb.tt0) - (pa.tt0 < pb.tt0);
}

private void vosfile_read_midi(VosSong *song, FILE *file, uint mid_ofs, uint mid_len, double tempo_factor)
{
  int result;
  char[4] magic;
  uint header_len, fmt, ppqn, i;
  TempoChange[] tempo_arr;
//   GArray *tempo_arr;
  TempoChange tc;
  
  result = fseek(file, mid_ofs, SEEK_SET); enforce(result == 0);
  result = fread(&magic[0], 4, 1, file); enforce(result == 1);
  enforce(to!string(magic) == "MThd", to!string(magic));
  header_len = midi_read_u32(file); enforce(header_len == 6, to!string(header_len));
  fmt = midi_read_u16(file); enforce(fmt == 1);
  song.ntrack = midi_read_u16(file); enforce(song.ntrack > 0);
  ppqn = midi_read_u16(file); enforce((ppqn & 0x8000) == 0); /* Actually a ppqn */
  song.midi_unit_tt = 1.0 / ppqn;

  song.tracks = cast(MidiTrack*) malloc(MidiTrack.sizeof * song.ntrack);
  // song.tracks = g_new0(MidiTrack, song.ntrack);
//   tempo_arr = g_array_new(FALSE, FALSE, sizeof(TempoChange));
  tc.rt0 = 0.0; tc.tt0 = 0.0; tc.qn_time = 0.5; tempo_arr ~= tc; //g_array_append_val(tempo_arr, tc); /* 120 BPM, the default */
  for (i = 0; i < song.ntrack; i++) {
    MidiTrack *track = &song.tracks[i];
    // GArray *event_arr = g_array_new(FALSE, FALSE, sizeof(MidiEvent));
    MidiEvent[] event_arr;
    uint track_ofs, track_len;
    ubyte cmd = 0; /* The status byte */
    ubyte ch;
    uint time = 0; /* In MIDI units */
    bool is_eot = false; /* Found "End of Track"? */

    result = fread(&magic[0], 4, 1, file); enforce(result == 1);
    enforce(to!string(magic) == "MTrk");
    track_len = midi_read_u32(file);
    track_ofs = ftell(file);
    while (cast(uint) ftell(file) < track_ofs + track_len) {
      MidiEvent ev;
      double tt;
      
      enforce(! is_eot);
      memset(&ev, 0, MidiEvent.sizeof);
      time += midi_read_vl(file); tt = time * song.midi_unit_tt;
      ch = midi_read_u8(file);
      if (ch == 0xff) { /* Meta event */
	uint meta_type = midi_read_u8(file);
	uint meta_len = midi_read_vl(file);
	switch (meta_type) {
	default:
	  // g_warning("Unknown meta event type 0x%02x", meta_type);
	  /* fall through */
	case 0x03: /* Sequence/Track name */
	case 0x21: /* MIDI port number */
	case 0x58: /* Time signature */
	case 0x59: /* Key signature */
	  result = fseek(file, meta_len, SEEK_CUR); enforce(result == 0); /* skip over the data */
	  break;
	case 0x2f: /* End of track */
	  enforce(meta_len == 0); is_eot = true; break;
	case 0x51: /* Tempo */
	  {
	    ubyte[3] buf;
	    uint val;

	    /* NOTE: If tempo changes exist in multiple tracks (e.g. 2317.vos), the array will be out of order.  Therefore,
	       we set rt0 only after sorting them. */
	    enforce(meta_len == 3);
	    result = fread(&buf[0], meta_len, 1, file); enforce(result == 1);
	    val = (cast(uint) buf[0] << 16) | (cast(uint) buf[1] << 8) | buf[2];
	    tc.tt0 = tt; tc.rt0 = 0.0; tc.qn_time = val * 1e-6 / tempo_factor; tempo_arr ~= tc; //g_array_append_val(tempo_arr, tc);
	  }
	  break;
	}
	continue;
      } else if (ch == 0xf0) { /* SysEx event */
	uint sysex_len = midi_read_vl(file);
	/* Just ignore it */
	result = fseek(file, sysex_len, SEEK_CUR); enforce(result == 0);
      } else {
	uint cmd_type;
	if (ch & 0x80) { cmd = ch; ch = midi_read_u8(file); }
	cmd_type = (cmd & 0x7f) >> 4; enforce(cmd_type != 7);
	ev.cmd = cmd; ev.a = ch;
	/* Program Change and Channel Pressure messages have one status bytes, all others have two */
	if (! (cmd_type == 4 || cmd_type == 5)) ev.b = midi_read_u8(file);
      }
      ev.tt = tt;
      // g_array_append_val(event_arr, ev);
      event_arr ~= ev;
    }
    enforce(is_eot);
    enforce(cast(uint) ftell(file) == track_ofs + track_len);
    track.nevent = event_arr.length;
    track.events = event_arr.length == 0 ? null : &event_arr[0]; //cast(MidiEvent *) g_array_free(event_arr, FALSE);
  }
  tempo_arr.sort!((a, b) => (a.tt0 < b.tt0));
//   g_array_sort(tempo_arr, tempo_change_compare);
  
  song.ntempo = tempo_arr.length;
  song.tempos = &tempo_arr[0]; //cast(TempoChange *) g_array_free(tempo_arr, FALSE);
  for (i = 1; i < song.ntempo; i++) { /* song.tempos[0].rt0 has been set to zero */
    const TempoChange *last_tc = &song.tempos[i-1];
    TempoChange *tcp = &song.tempos[i];
    tcp.rt0 = last_tc.rt0 + last_tc.qn_time * (tcp.tt0 - last_tc.tt0);
  }
}

private ubyte vosfile_read_u8(FILE *file)
{
  int result = getc(file);

  enforce(result != EOF);
  return cast(ubyte) result;
}

/* Little endian */
private ushort vosfile_read_u16(FILE *file)
{
  ushort tmp;
  int result;

  result = fread(&tmp, 2, 1, file); enforce(result == 1);
  if(std.system.endian == Endian.bigEndian)
    return peek!(ushort, Endian.bigEndian)(nativeToLittleEndian(tmp)[0..$]);
  else
    return tmp;
}

private uint vosfile_read_u32(FILE *file)
{
  uint tmp;
  int result;

  result = fread(&tmp, 4, 1, file); enforce(result == 1);
  if(std.system.endian == Endian.bigEndian)
    return peek!(uint, Endian.bigEndian)(nativeToLittleEndian(tmp)[0..$]);
  else
    return tmp;
}

private char *vosfile_read_string(FILE *file)
{
  uint len;
  char *buf;
  int result;

  len = vosfile_read_u8(file); buf = cast(char*) malloc(char.sizeof * (len+1));
  result = fread(buf, 1, len, file); enforce(result == cast(int) len);
  buf[len] = '\0';
  return buf;
}

private char *vosfile_read_string2(FILE *file)
{
  uint len;
  char *buf;
  int result;

  len = vosfile_read_u16(file); buf = cast(char*) malloc(char.sizeof * (len+1));
  result = fread(buf, 1, len, file); enforce(result == cast(int) len);
  buf[len] = '\0';
  return buf;
}

private char *vosfile_read_string_fixed(FILE *file, uint len)
{
  char *buf;
  int result;
  
  buf = cast(char*) malloc(char.sizeof * (len+1));
  result = fread(buf, 1, len, file); enforce(result == cast(int) len);
  buf[len] = '\0';
  return buf;
}

private void vosfile_read_info(VosSong *song, FILE *file, uint inf_ofs, uint inf_len)
{
  int result;
  uint inf_end_ofs = inf_ofs + inf_len, cur_ofs, next_ofs, key;
  char* title, artist, comment, vos_author;
  uint song_type, ext_type, song_length, level;
  char[4] buf;
  // GArray *note_arrays_arr = g_array_new(FALSE, FALSE, sizeof(NoteArray));
  NoteArray[] note_arrays_arr;
  // GArray *user_notes_arr = g_array_new(FALSE, FALSE, sizeof(UserNote));
  UserNote[] user_notes_arr;
  uint[NKEY] last_note_idx, last_note_idx_long;
  uint cur_un_idx;
  uint[NKEY] count, count_long;

  result = fseek(file, inf_ofs, SEEK_SET); enforce(result == 0);
  /* Skip the "VOS1" header in e.g. test3.vos and test4.vos, if any */
  result = fread(&buf[0], 4, 1, file);
  if (result == 1 && to!string(buf) == "VOS1") { /* Found "VOS1" header */
    char *str1;
    result = fseek(file, 66, SEEK_CUR); enforce(result == 0);
    str1 = vosfile_read_string(file); free(str1);
  } else {
    result = fseek(file, inf_ofs, SEEK_SET); enforce(result == 0);
  }
  title = vosfile_read_string(file); free(title); // print_vosfile_string_v("Title", title); g_free(title);
  artist = vosfile_read_string(file); free(artist); //print_vosfile_string_v("Artist", artist); g_free(artist);
  comment = vosfile_read_string(file); free(comment); //print_vosfile_string_v("Comment", comment); g_free(comment);
  vos_author = vosfile_read_string(file); free(vos_author); //print_vosfile_string_v("VOS Author", vos_author); g_free(vos_author);
  song_type = vosfile_read_u8(file); ext_type = vosfile_read_u8(file);
  song_length = vosfile_read_u32(file);
  level = vosfile_read_u8(file); //if (verbose) g_message("Level: %u", level + 1);

  result = fseek(file, 1023, SEEK_CUR); enforce(result == 0);
  result = ftell(file); enforce(result != -1); cur_ofs = result;
  for (key = 0; key < NKEY; key++) {
    count[key] = 0; count_long[key] = 0;
    last_note_idx[key] = IDX_NONE; last_note_idx_long[key] = IDX_NONE;
    song.first_un_idxs[key] = IDX_NONE; song.first_un_idxs_long[key] = IDX_NONE;
  }
  cur_un_idx = 0;
  while (1) {
    uint type, nnote, i;
    bool is_user_arr; /* Whether the current note array is the one to be played by the user. */
    char[14] dummy2;
    NoteArray cur_note_arr;
    TempoIt it;

    result = ftell(file); enforce(result != -1); cur_ofs = result;
    if (cur_ofs == inf_end_ofs) break;
    type = vosfile_read_u32(file); nnote = vosfile_read_u32(file);
    next_ofs = cur_ofs + nnote * 13 + 22; is_user_arr = (next_ofs == inf_end_ofs);
    result = fread(&dummy2[0], 14, 1, file); enforce(result == 1);
    for (i = 0; i < 14; i++) enforce(dummy2[i] == 0);

    memset(&cur_note_arr, 0, cur_note_arr.sizeof);
    it.idx = 0;
    if (! is_user_arr) { cur_note_arr.num_note = nnote; cur_note_arr.notes = cast(Note*) malloc(Note.sizeof * nnote); } //g_new0(Note, nnote); }
    for (i = 0; i < nnote; i++) {
      uint time, len;
      ubyte cmd, note_num, vol;
      uint flags;
      bool is_user_note, is_long;
      double tt_start, tt_end, rt_start, rt_end;
      
      time = vosfile_read_u32(file); len = vosfile_read_u32(file);
      cmd = vosfile_read_u8(file); note_num = vosfile_read_u8(file); vol = vosfile_read_u8(file);
      flags = vosfile_read_u16(file); is_user_note = ((flags & 0x80) != 0); is_long = ((flags & 0x8000) != 0);

      tt_start = time / 768.0; tt_end = (time + len) / 768.0;
      rt_start = tempoit_tt_to_rt(song, &it, tt_start); rt_end = tempoit_tt_to_rt(song, &it, tt_end);
      if (song.has_min_max_rt) { song.min_rt = min(song.min_rt, rt_start); song.max_rt = max(song.max_rt, rt_end); }
      else { song.min_rt = rt_start; song.max_rt = rt_end; song.has_min_max_rt = true; }
      if (! is_user_arr) {
        Note *note = &cur_note_arr.notes[i];
        note.tt_start = tt_start; note.tt_end = tt_end;
        note.rt_start = rt_start; note.rt_end = rt_end;
        note.cmd = cmd; note.note_num = note_num; note.vol = vol;
        note.is_user = is_user_note; note.is_long = is_long;
      } else {
        UserNote un;
        
        enforce(is_user_note);
        memset(&un, 0, UserNote.sizeof);
        un.tt_start = tt_start; un.rt_start = rt_start;
        un.tt_end = tt_end; un.rt_end = rt_end;
        un.cmd = cmd; un.note_num = note_num; un.vol = vol;
        un.key = (flags & 0x70) >> 4; un.color = (flags & 0x0f); un.is_long = is_long;
        un.tt_stop = (un.is_long) ? un.tt_end : un.tt_start;
        un.rt_stop = (un.is_long) ? un.rt_end : un.rt_start;
        enforce(un.key < NKEY);
        un.prev_idx = last_note_idx[un.key]; un.next_idx = IDX_NONE;
        if (last_note_idx[un.key] != IDX_NONE) {
          UserNote *last_un = &user_notes_arr[last_note_idx[un.key]]; // g_array_index(user_notes_arr, UserNote, last_note_idx[un.key]);
          if (un.tt_start < last_un.tt_stop) { /* Notes on the same key should never overlap */
            //g_warning("User note %u ignored because of overlapping notes.", i);
            goto skip_user_note;
          }
          last_un.next_idx = cur_un_idx;
        } else song.first_un_idxs[un.key] = cur_un_idx; /* First note on this key */
        last_note_idx[un.key] = cur_un_idx;
        un.count = ++count[un.key];
        if (un.is_long) {
          un.prev_idx_long = last_note_idx_long[un.key]; un.next_idx_long = IDX_NONE;
          if (last_note_idx_long[un.key] != IDX_NONE)
            user_notes_arr[last_note_idx_long[un.key]].next_idx_long = cur_un_idx; // g_array_index(user_notes_arr, UserNote, last_note_idx_long[un.key]).next_idx_long = cur_un_idx;
          else song.first_un_idxs_long[un.key] = cur_un_idx;
          last_note_idx_long[un.key] = cur_un_idx;
          un.count_long = ++count_long[un.key];
        } else { un.prev_idx_long = IDX_NONE; un.next_idx_long = IDX_NONE; }
        user_notes_arr ~= un; cur_un_idx++; // g_array_append_val(user_notes_arr, un); cur_un_idx++;
            skip_user_note: ;
      }
    }
    if (! is_user_arr) note_arrays_arr ~= cur_note_arr; //g_array_append_val(note_arrays_arr, cur_note_arr);
    cur_ofs = next_ofs; enforce(cast(uint) ftell(file) == cur_ofs);
  }
  song.num_note_array = note_arrays_arr.length;
  song.note_arrays = &note_arrays_arr[0]; //cast(NoteArray *) g_array_free(note_arrays_arr, FALSE);
  song.num_user_note = user_notes_arr.length;
  song.user_notes = &user_notes_arr[0]; // cast(UserNote *) g_array_free(user_notes_arr, FALSE);
}

private void vosfile_read_info_022(VosSong *song, FILE *file, uint inf_ofs, uint inf_len)
{
  int result;
  char* title, artist, comment, vos_author, str;
  uint fileversion;
  uint song_length, level, x;
  uint i, j, k, key;
  uint narr, nunote; /* NOTE: due to the deletion of buggy notes, song.num_user_note may be smaller than nunote */
  char[6] magic;
  char[11] unknown1;
  // GArray *user_notes_arr = g_array_new(FALSE, FALSE, sizeof(UserNote));
  UserNote[] user_notes_arr;
  uint[NKEY] last_note_idx, last_note_idx_long;
  uint cur_un_idx;
  uint[NKEY] count, count_long;

  result = fseek(file, inf_ofs, SEEK_SET); enforce(result == 0);
  result = fread(&magic[0], 6, 1, file); enforce(result == 1);
  if (to!string(magic) == "VOS022") fileversion = 22;
  else if (to!string(magic) == "VOS006") fileversion = 6;
  else throw new Exception(""); //TODO: put exception here

  title = vosfile_read_string2(file); free(title); // print_vosfile_string_v("Title", title); g_free(title);
  artist = vosfile_read_string2(file); free(artist); // print_vosfile_string_v("Artist", artist); g_free(artist);
  comment = vosfile_read_string2(file); free(comment); // print_vosfile_string_v("Comment", comment); g_free(comment);
  vos_author = vosfile_read_string2(file); free(vos_author); // print_vosfile_string_v("VOS Author", vos_author); g_free(vos_author);
  str = vosfile_read_string2(file); free(str); // g_free(str);
  result = fread(&unknown1[0], 11, 1, file); enforce(result == 1);
  x = vosfile_read_u32(file); /* song_length_tt? */ song_length = vosfile_read_u32(file);

  result = fseek(file, 1024, SEEK_CUR); enforce(result == 0);
  narr = vosfile_read_u32(file); x = vosfile_read_u32(file); enforce(x == 1);
  song.num_note_array = narr; song.note_arrays = cast(NoteArray*) malloc(NoteArray.sizeof * narr); // g_new0(NoteArray, narr);
  for (k = 0; k < narr; k++) {
    x = vosfile_read_u8(file); enforce(x == 4);
    x = vosfile_read_u32(file); /* type */
  }
  x = vosfile_read_u8(file); enforce(x == 0);
  level = vosfile_read_u8(file); // if (verbose) g_message("Level: %u", level + 1);
  str = vosfile_read_string2(file); free(str); // g_free(str);
  x = vosfile_read_u32(file); enforce(x == 0);

  for (key = 0; key < NKEY; key++) {
    count[key] = 0; count_long[key] = 0;
    last_note_idx[key] = IDX_NONE; last_note_idx_long[key] = IDX_NONE;
    song.first_un_idxs[key] = IDX_NONE; song.first_un_idxs_long[key] = IDX_NONE;
  }
  cur_un_idx = 0;

  /* Notes */
  for (k = 0; k < narr; k++) {
    uint nnote;
    TempoIt it;
    NoteArray *cur_note_arr = &song.note_arrays[k];

    nnote = vosfile_read_u32(file);
    cur_note_arr.num_note = nnote; cur_note_arr.notes = cast(Note*) malloc(Note.sizeof * nnote); // g_new0(Note, nnote);
    it.idx = 0; // tempoit_init(song, &it);
    for (i = 0; i < nnote; i++) {
      uint time, len;
      ubyte cmd, note_num, vol;
      uint track;
      bool is_user_note, is_long;
      double tt_start, tt_end, rt_start, rt_end;
      Note *note = &cur_note_arr.notes[i];

      x = vosfile_read_u8(file); enforce(x == 0);
      time = vosfile_read_u32(file); note_num = vosfile_read_u8(file);
      track = vosfile_read_u8(file); cmd = cast(ubyte) (track | 0x90);
      vol = vosfile_read_u8(file); is_user_note = cast(bool) vosfile_read_u8(file);
      x = vosfile_read_u8(file);
      is_long = cast(bool) vosfile_read_u8(file); len = vosfile_read_u32(file);
      x = vosfile_read_u8(file); enforce(x == 0x00 || x == 0xff);
      /* This is true for most files, but 994.vos is an exception */
      // g_assert(x == (is_user_note ? 0x00 : 0xff));
      tt_start = time / 768.0; tt_end = (time + len) / 768.0;
      rt_start = tempoit_tt_to_rt(song, &it, tt_start); rt_end = tempoit_tt_to_rt(song, &it, tt_end);
      if (song.has_min_max_rt) { song.min_rt = min(song.min_rt, rt_start); song.max_rt = max(song.max_rt, rt_end); }
      else { song.min_rt = rt_start; song.max_rt = rt_end; song.has_min_max_rt = true; }
      
      note.tt_start = tt_start; note.tt_end = tt_end;
      note.rt_start = rt_start; note.rt_end = rt_end;
      note.cmd = cmd; note.note_num = note_num; note.vol = vol;
      note.is_user = is_user_note; note.is_long = is_long;
    }
  }

  /* User notes */
  if (fileversion == 22) { x = vosfile_read_u32(file); enforce(x == 0); }
  nunote = vosfile_read_u32(file);
  for (j = 0; j < nunote; j++) {
    NoteArray *cur_note_arr;
    Note *note;
    UserNote un;
    
    k = vosfile_read_u8(file); enforce(k < narr); cur_note_arr = &song.note_arrays[k];
    i = vosfile_read_u32(file); enforce(i < cur_note_arr.num_note); note = &cur_note_arr.notes[i];
    key = vosfile_read_u8(file);
    
    enforce(note.is_user);
    memset(&un, 0, un.sizeof);
    un.tt_start = note.tt_start; un.rt_start = note.rt_start;
    un.tt_end = note.tt_end; un.rt_end = note.rt_end;
    un.cmd = cast(ubyte) note.cmd; un.note_num = cast(ubyte) note.note_num; un.vol = cast(ubyte) note.vol;
    un.key = key; un.color = (k & 0x0f); un.is_long = note.is_long;
    un.tt_stop = (un.is_long) ? un.tt_end : un.tt_start;
    un.rt_stop = (un.is_long) ? un.rt_end : un.rt_start;
    enforce(un.key < NKEY);
    un.prev_idx = last_note_idx[un.key]; un.next_idx = IDX_NONE;
    if (last_note_idx[un.key] != IDX_NONE) {
      UserNote *last_un = &user_notes_arr[last_note_idx[un.key]]; // g_array_index(user_notes_arr, UserNote, last_note_idx[un.key]);
      if (un.tt_start < last_un.tt_stop) { /* Notes on the same key should never overlap */
	      // g_warning("User note %u ignored because of overlapping notes.", i);
	      goto skip_user_note;
      }
      last_un.next_idx = cur_un_idx;
    } else song.first_un_idxs[un.key] = cur_un_idx; /* First note on this key */
    last_note_idx[un.key] = cur_un_idx;
    un.count = ++count[un.key];
    if (un.is_long) {
      un.prev_idx_long = last_note_idx_long[un.key]; un.next_idx_long = IDX_NONE;
      if (last_note_idx_long[un.key] != IDX_NONE){
	// g_array_index(user_notes_arr, UserNote, last_note_idx_long[un.key]).next_idx_long = cur_un_idx;
        user_notes_arr[last_note_idx_long[un.key]].next_idx_long = cur_un_idx;
      }
      else song.first_un_idxs_long[un.key] = cur_un_idx;
      last_note_idx_long[un.key] = cur_un_idx;
      un.count_long = ++count_long[un.key];
    } else { un.prev_idx_long = IDX_NONE; un.next_idx_long = IDX_NONE; }
    // g_array_append_val(user_notes_arr, un); cur_un_idx++;
    user_notes_arr ~= un; cur_un_idx++;
  skip_user_note: ;    
  }
  song.num_user_note = user_notes_arr.length;
  song.user_notes = &user_notes_arr[0]; // cast(UserNote *) g_array_free(user_notes_arr, FALSE);

  /* What follows is the lyric, which we ignore for now. */
}

private void vosfile_read_vos1(VosSong *song, FILE *file, uint file_size, double tempo_factor)
{
  uint ofs, next_ofs;
  uint inf_ofs = 0, inf_len = 0, mid_ofs = 0, mid_len = 0;
  char *seg_name;
  
  /* Read the segments */
  ofs = vosfile_read_u32(file);
  while (1) {
    seg_name = vosfile_read_string_fixed(file, 16);
    if (strcmp(seg_name, "EOF") == 0 || ofs == file_size) { /*g_free(seg_name);*/ free(seg_name); break; }
    next_ofs = vosfile_read_u32(file);
    if (strcmp(seg_name, "inf") == 0) { inf_ofs = ofs; inf_len = next_ofs - ofs; }
    else if (strcmp(seg_name, "mid") == 0) { mid_ofs = ofs; mid_len = next_ofs - ofs; }
    else throw new Exception(""); //TODO: put exception here //enforce_not_reached();
    free(seg_name); //g_free(seg_name);
    ofs = next_ofs;
  }
  enforce(inf_len != 0); enforce(mid_len != 0);

  vosfile_read_midi(song, file, mid_ofs, mid_len, tempo_factor);
  vosfile_read_info(song, file, inf_ofs, inf_len);
}

private void vosfile_read_vos022(VosSong *song, FILE *file, uint file_size, double tempo_factor)
{
  int result;
  uint inf_ofs = IDX_NONE, inf_len = 0, mid_ofs = IDX_NONE, mid_len = 0;
  uint subfile_idx = 0, ofs = 4, data_ofs;
  uint fname_len, len;
  char *fname;

  while (1) {
    if (ofs == file_size) break;
    result = fseek(file, ofs, SEEK_SET); enforce(result == 0);
    fname_len = vosfile_read_u32(file);
    fname = vosfile_read_string_fixed(file, fname_len);
    len = vosfile_read_u32(file); data_ofs = ofs + 4 + fname_len + 4;
    if (subfile_idx == 0) { enforce(strcmp(fname, "Vosctemp.trk") == 0, to!string(fname)); inf_ofs = data_ofs; inf_len = len; }
    else if (subfile_idx == 1) {
      enforce(strcmp(fname, "VOSCTEMP.mid") == 0, to!string(fname)); mid_ofs = data_ofs, mid_len = len;
    } else throw new Exception(""); //TODO: put error message here // enforce_not_reached();
    free(fname); // g_free(fname);
    ofs = data_ofs + len; subfile_idx++;
  }
  enforce(inf_ofs != IDX_NONE); enforce(mid_ofs != IDX_NONE);

  vosfile_read_midi(song, file, mid_ofs, mid_len, tempo_factor);
  vosfile_read_info_022(song, file, inf_ofs, inf_len);
}

//Default tempo_factor is 1.0
public VosSong* read_vos_file(const char *fname, double tempo_factor)
{
  VosSong *song;
  FILE *file;
  uint magic, file_size;
  int result;
  
  file = fopen(fname, "rb"); enforce(file != null);
  song = cast(VosSong*) malloc(VosSong.sizeof); /* g_new0(VosSong, 1); */ song.has_min_max_rt = false;
  hash_file(file, &song.hash[0]);
  result = fseek(file, 0, SEEK_END); enforce(result == 0);
  file_size = ftell(file);
  result = fseek(file, 0, SEEK_SET); enforce(result == 0);
  magic = vosfile_read_u32(file);
  if (magic == 3) vosfile_read_vos1(song, file, file_size, tempo_factor);
  else if (magic == 2) vosfile_read_vos022(song, file, file_size, tempo_factor);
  else throw new Exception(to!string(magic)); //TODO: add error message // enforce_not_reached();
  
  fclose(file);
  return song;
}

unittest
{
  VosSong* song = read_vos_file("./bin/1.vos\0", 1.0);
  writeln("ntempo: ", song.ntempo);
  assert(song.ntempo == 3);
  // for(int i = 0; i < song.ntempo; i++)
  //   writeln(format("rt0:%s tt0:%s qn_time:%s", song.tempos[i].rt0, song.tempos[i].tt0, song.tempos[i].qn_time));
  writeln("midi_unit_tt: ", song.midi_unit_tt);
  assert(std.math.abs(song.midi_unit_tt - (1.0/120)) < double.epsilon);
  writeln("ntrack: ", song.ntrack);
  assert(song.ntrack == 13);

  writeln("num_note_array: ", song.num_note_array);
  assert(song.num_note_array == 10);

  writeln("num_user_note: ", song.num_user_note);
  assert(song.num_user_note == 225);

  writeln("has_min_max_rt: ", song.has_min_max_rt);
  assert(song.has_min_max_rt);

  writeln(format("min_rt:%.20g max_rt:%.20g", song.min_rt, song.max_rt));
  assert(std.math.feqrel(song.min_rt, 2.31124) >= 24);
  assert(std.math.feqrel(song.max_rt, 178.457385) >= 28);

  writeln(song.first_un_idxs);
  assert(equal(song.first_un_idxs[0..$], [0, 2, 8, 9, 13, 37, 1]));
  writeln(song.first_un_idxs_long);
  assert(equal(song.first_un_idxs_long[0..$], [50, 6, 17, 102, 36, 118, 35]));

  writeln(song.hash);
  assert(equal(song.hash[0..$], [105, 0, 99, 0, 92, 0, 98, 0, 105, 0, 110, 0, 92, 0, 49, 0, 46, 0, 118, 0]));
}