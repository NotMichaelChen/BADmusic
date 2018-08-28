module vosparser.parse;

//A translation of the parser from https://github.com/felixonmars/pmgmusic

enum NKEY = 7;
enum SHA_DIGEST_LENGTH = 20;

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
  uint first_un_idxs[NKEY]; /* The first user note on each key */
  uint first_un_idxs_long[NKEY]; /* The first long user note */
  ubyte hash[SHA_DIGEST_LENGTH];
}

enum BUF_SIZE = 4096;
static void hash_file(FILE *file, unsigned char *hash, unsigned hash_len)
{
  static char buf[BUF_SIZE];
  unsigned cur_len;
  EVP_MD_CTX mdctx;
  const EVP_MD *md = EVP_sha1();
  int result;

  g_assert(EVP_MD_size(md) == (int) hash_len);
  result = EVP_DigestInit(&mdctx, md); g_assert(result == 1);
  result = fseek(file, 0, SEEK_SET); g_assert(result == 0);
  while (1) {
    result = fread(buf, 1, BUF_SIZE, file); g_assert(result >= 0); cur_len = result;
    if (cur_len == 0) break;
    result = EVP_DigestUpdate(&mdctx, buf, cur_len); g_assert(result == 1);
  }
  result = EVP_DigestFinal(&mdctx, hash, NULL); g_assert(result == 1);
}

static unsigned midi_read_u8(FILE *file)
{
  int result = getc(file);
  g_assert(result != EOF);
  return (unsigned) result;
}

static unsigned midi_read_u16(FILE *file)
{
  guint16 tmp;
  int result;

  result = fread(&tmp, 2, 1, file); g_assert(result == 1);
  return GUINT16_FROM_BE(tmp);
}

static unsigned midi_read_u32(FILE *file)
{
  guint32 tmp;
  int result;

  result = fread(&tmp, 4, 1, file); g_assert(result == 1);
  return GUINT32_FROM_BE(tmp);
}

static unsigned midi_read_vl(FILE *file)
{
  int result;
  unsigned x = 0;

  while (1) {
    result = getc(file); g_assert(result != EOF);
    x |= (result & 0x7f);
    if (result & 0x80) x <<= 7;
    else break;
  }
  return x;
}

static int tempo_change_compare(gconstpointer pa, gconstpointer pb)
{
  const TempoChange *a = (const TempoChange *) pa, *b = (const TempoChange *) pb;
  return (a->tt0 > b->tt0) - (a->tt0 < b->tt0);
}

static void vosfile_read_midi(VosSong *song, FILE *file, unsigned mid_ofs, unsigned mid_len, double tempo_factor)
{
  int result;
  char magic[4];
  unsigned header_len, fmt, ppqn, i;
  GArray *tempo_arr;
  TempoChange tc;
  
  result = fseek(file, mid_ofs, SEEK_SET); g_assert(result == 0);
  result = fread(magic, 4, 1, file); g_assert(result == 1);
  g_assert(memcmp(magic, "MThd", 4) == 0);
  header_len = midi_read_u32(file); g_assert(header_len == 6);
  fmt = midi_read_u16(file); g_assert(fmt == 1);
  song->ntrack = midi_read_u16(file); g_assert(song->ntrack > 0);
  ppqn = midi_read_u16(file); g_assert((ppqn & 0x8000) == 0); /* Actually a ppqn */
  song->midi_unit_tt = 1.0 / ppqn;

  song->tracks = g_new0(MidiTrack, song->ntrack);
  tempo_arr = g_array_new(FALSE, FALSE, sizeof(TempoChange));
  tc.rt0 = 0.0; tc.tt0 = 0.0; tc.qn_time = 0.5; g_array_append_val(tempo_arr, tc); /* 120 BPM, the default */
  for (i = 0; i < song->ntrack; i++) {
    MidiTrack *track = &song->tracks[i];
    GArray *event_arr = g_array_new(FALSE, FALSE, sizeof(MidiEvent));
    unsigned track_ofs, track_len;
    unsigned char cmd = 0; /* The status byte */
    unsigned char ch;
    unsigned time = 0; /* In MIDI units */
    gboolean is_eot = FALSE; /* Found "End of Track"? */

    result = fread(magic, 4, 1, file); g_assert(result == 1);
    g_assert(memcmp(magic, "MTrk", 4) == 0);
    track_len = midi_read_u32(file);
    track_ofs = ftell(file);
    while ((unsigned) ftell(file) < track_ofs + track_len) {
      MidiEvent ev;
      double tt;
      
      g_assert(! is_eot);
      memset(&ev, 0, sizeof(ev));
      time += midi_read_vl(file); tt = time * song->midi_unit_tt;
      ch = midi_read_u8(file);
      if (ch == 0xff) { /* Meta event */
	unsigned meta_type = midi_read_u8(file);
	unsigned meta_len = midi_read_vl(file);
	switch (meta_type) {
	default:
	  g_warning("Unknown meta event type 0x%02x", meta_type);
	  /* fall through */
	case 0x03: /* Sequence/Track name */
	case 0x21: /* MIDI port number */
	case 0x58: /* Time signature */
	case 0x59: /* Key signature */
	  result = fseek(file, meta_len, SEEK_CUR); g_assert(result == 0); /* skip over the data */
	  break;
	case 0x2f: /* End of track */
	  g_assert(meta_len == 0); is_eot = TRUE; break;
	case 0x51: /* Tempo */
	  {
	    unsigned char buf[3];
	    unsigned val;

	    /* NOTE: If tempo changes exist in multiple tracks (e.g. 2317.vos), the array will be out of order.  Therefore,
	       we set rt0 only after sorting them. */
	    g_assert(meta_len == 3);
	    result = fread(buf, meta_len, 1, file); g_assert(result == 1);
	    val = ((unsigned) buf[0] << 16) | ((unsigned) buf[1] << 8) | buf[2];
	    tc.tt0 = tt; tc.rt0 = 0.0; tc.qn_time = val * 1e-6 / tempo_factor; g_array_append_val(tempo_arr, tc);
	  }
	  break;
	}
	continue;
      } else if (ch == 0xf0) { /* SysEx event */
	unsigned sysex_len = midi_read_vl(file);
	/* Just ignore it */
	result = fseek(file, sysex_len, SEEK_CUR); g_assert(result == 0);
      } else {
	unsigned cmd_type;
	if (ch & 0x80) { cmd = ch; ch = midi_read_u8(file); }
	cmd_type = (cmd & 0x7f) >> 4; g_assert(cmd_type != 7);
	ev.cmd = cmd; ev.a = ch;
	/* Program Change and Channel Pressure messages have one status bytes, all others have two */
	if (! (cmd_type == 4 || cmd_type == 5)) ev.b = midi_read_u8(file);
      }
      ev.tt = tt;
      g_array_append_val(event_arr, ev);
    }
    g_assert(is_eot);
    g_assert((unsigned) ftell(file) == track_ofs + track_len);
    track->nevent = event_arr->len;
    track->events = (MidiEvent *) g_array_free(event_arr, FALSE);
  }
  g_array_sort(tempo_arr, tempo_change_compare);
  song->ntempo = tempo_arr->len;
  song->tempos = (TempoChange *) g_array_free(tempo_arr, FALSE);
  for (i = 1; i < song->ntempo; i++) { /* song->tempos[0].rt0 has been set to zero */
    const TempoChange *last_tc = &song->tempos[i-1];
    TempoChange *tc = &song->tempos[i];
    tc->rt0 = last_tc->rt0 + last_tc->qn_time * (tc->tt0 - last_tc->tt0);
  }
  if (verbose) {
    for (i = 0; i < song->ntempo; i++) {
      const TempoChange *tc = &song->tempos[i];
      int rtt = (int) tc->rt0;
      g_message("Tempo at %d:%02d: %d bpm", rtt / 60, rtt % 60, (int) floor(60.0 / tc->qn_time + 0.5));
    }
  }
}

static unsigned vosfile_read_u8(FILE *file)
{
  int result = getc(file);

  g_assert(result != EOF);
  return (unsigned) result;
}

/* Little endian */
static unsigned vosfile_read_u16(FILE *file)
{
  guint16 tmp;
  int result;

  result = fread(&tmp, 2, 1, file); g_assert(result == 1);
  return GUINT16_FROM_LE(tmp);
}

static unsigned vosfile_read_u32(FILE *file)
{
  guint32 tmp;
  int result;

  result = fread(&tmp, 4, 1, file); g_assert(result == 1);
  return GUINT32_FROM_LE(tmp);
}

static char *vosfile_read_string(FILE *file)
{
  unsigned len;
  char *buf;
  int result;

  len = vosfile_read_u8(file); buf = g_new0(char, len + 1);
  result = fread(buf, 1, len, file); g_assert(result == (int) len);
  return buf;
}

static char *vosfile_read_string2(FILE *file)
{
  unsigned len;
  char *buf;
  int result;

  len = vosfile_read_u16(file); buf = g_new0(char, len + 1);
  result = fread(buf, 1, len, file); g_assert(result == (int) len);
  return buf;
}

static char *vosfile_read_string_fixed(FILE *file, unsigned len)
{
  char *buf;
  int result;
  
  buf = g_new0(char, len + 1);
  result = fread(buf, 1, len, file); g_assert(result == (int) len);
  return buf;
}

static void vosfile_read_info(VosSong *song, FILE *file, unsigned inf_ofs, unsigned inf_len)
{
  int result;
  unsigned inf_end_ofs = inf_ofs + inf_len, cur_ofs, next_ofs, key;
  char *title, *artist, *comment, *vos_author;
  unsigned song_type, ext_type, song_length, level;
  char buf[4];
  GArray *note_arrays_arr = g_array_new(FALSE, FALSE, sizeof(NoteArray));
  GArray *user_notes_arr = g_array_new(FALSE, FALSE, sizeof(UserNote));
  unsigned last_note_idx[NKEY], last_note_idx_long[NKEY], cur_un_idx;
  unsigned count[NKEY], count_long[NKEY];

  result = fseek(file, inf_ofs, SEEK_SET); g_assert(result == 0);
  /* Skip the "VOS1" header in e.g. test3.vos and test4.vos, if any */
  result = fread(buf, 4, 1, file);
  if (result == 1 && memcmp(buf, "VOS1", 4) == 0) { /* Found "VOS1" header */
    char *str1;
    result = fseek(file, 66, SEEK_CUR); g_assert(result == 0);
    str1 = vosfile_read_string(file); g_free(str1);
  } else {
    result = fseek(file, inf_ofs, SEEK_SET); g_assert(result == 0);
  }
  title = vosfile_read_string(file); print_vosfile_string_v("Title", title); g_free(title);
  artist = vosfile_read_string(file); print_vosfile_string_v("Artist", artist); g_free(artist);
  comment = vosfile_read_string(file); print_vosfile_string_v("Comment", comment); g_free(comment);
  vos_author = vosfile_read_string(file); print_vosfile_string_v("VOS Author", vos_author); g_free(vos_author);
  song_type = vosfile_read_u8(file); ext_type = vosfile_read_u8(file);
  song_length = vosfile_read_u32(file);
  level = vosfile_read_u8(file); if (verbose) g_message("Level: %u", level + 1);

  result = fseek(file, 1023, SEEK_CUR); g_assert(result == 0);
  result = ftell(file); g_assert(result != -1); cur_ofs = result;
  for (key = 0; key < NKEY; key++) {
    count[key] = 0; count_long[key] = 0;
    last_note_idx[key] = IDX_NONE; last_note_idx_long[key] = IDX_NONE;
    song->first_un_idxs[key] = IDX_NONE; song->first_un_idxs_long[key] = IDX_NONE;
  }
  cur_un_idx = 0;
  while (1) {
    unsigned type, nnote, i;
    gboolean is_user_arr; /* Whether the current note array is the one to be played by the user. */
    char dummy2[14];
    NoteArray cur_note_arr;
    TempoIt it;

    result = ftell(file); g_assert(result != -1); cur_ofs = result;
    if (cur_ofs == inf_end_ofs) break;
    type = vosfile_read_u32(file); nnote = vosfile_read_u32(file);
    next_ofs = cur_ofs + nnote * 13 + 22; is_user_arr = (next_ofs == inf_end_ofs);
    result = fread(dummy2, 14, 1, file); g_assert(result == 1);
    for (i = 0; i < 14; i++) g_assert(dummy2[i] == 0);

    memset(&cur_note_arr, 0, sizeof(cur_note_arr));
    tempoit_init(song, &it);
    if (! is_user_arr) { cur_note_arr.num_note = nnote; cur_note_arr.notes = g_new0(Note, nnote); }
    for (i = 0; i < nnote; i++) {
      unsigned time, len;
      unsigned char cmd, note_num, vol;
      unsigned flags;
      gboolean is_user_note, is_long;
      double tt_start, tt_end, rt_start, rt_end;
      
      time = vosfile_read_u32(file); len = vosfile_read_u32(file);
      cmd = vosfile_read_u8(file); note_num = vosfile_read_u8(file); vol = vosfile_read_u8(file);
      flags = vosfile_read_u16(file); is_user_note = ((flags & 0x80) != 0); is_long = ((flags & 0x8000) != 0);

      tt_start = time / 768.0; tt_end = (time + len) / 768.0;
      rt_start = tempoit_tt_to_rt(song, &it, tt_start); rt_end = tempoit_tt_to_rt(song, &it, tt_end);
      if (song->has_min_max_rt) { song->min_rt = MIN(song->min_rt, rt_start); song->max_rt = MAX(song->max_rt, rt_end); }
      else { song->min_rt = rt_start; song->max_rt = rt_end; song->has_min_max_rt = TRUE; }
      if (! is_user_arr) {
        Note *note = &cur_note_arr.notes[i];
        note->tt_start = tt_start; note->tt_end = tt_end;
        note->rt_start = rt_start; note->rt_end = rt_end;
        note->cmd = cmd; note->note_num = note_num; note->vol = vol;
        note->is_user = is_user_note; note->is_long = is_long;
      } else {
        UserNote un;
        
        g_assert(is_user_note);
        memset(&un, 0, sizeof(un));
        un.tt_start = tt_start; un.rt_start = rt_start;
        un.tt_end = tt_end; un.rt_end = rt_end;
        un.cmd = cmd; un.note_num = note_num; un.vol = vol;
        un.key = (flags & 0x70) >> 4; un.color = (flags & 0x0f); un.is_long = is_long;
        un.tt_stop = (un.is_long) ? un.tt_end : un.tt_start;
        un.rt_stop = (un.is_long) ? un.rt_end : un.rt_start;
        g_assert(un.key < NKEY);
        un.prev_idx = last_note_idx[un.key]; un.next_idx = IDX_NONE;
        if (last_note_idx[un.key] != IDX_NONE) {
          UserNote *last_un = &g_array_index(user_notes_arr, UserNote, last_note_idx[un.key]);
          if (un.tt_start < last_un->tt_stop) { /* Notes on the same key should never overlap */
            g_warning("User note %u ignored because of overlapping notes.", i);
            goto skip_user_note;
          }
          last_un->next_idx = cur_un_idx;
        } else song->first_un_idxs[un.key] = cur_un_idx; /* First note on this key */
        last_note_idx[un.key] = cur_un_idx;
        un.count = ++count[un.key];
        if (un.is_long) {
          un.prev_idx_long = last_note_idx_long[un.key]; un.next_idx_long = IDX_NONE;
          if (last_note_idx_long[un.key] != IDX_NONE)
            g_array_index(user_notes_arr, UserNote, last_note_idx_long[un.key]).next_idx_long = cur_un_idx;
          else song->first_un_idxs_long[un.key] = cur_un_idx;
          last_note_idx_long[un.key] = cur_un_idx;
          un.count_long = ++count_long[un.key];
        } else { un.prev_idx_long = IDX_NONE; un.next_idx_long = IDX_NONE; }
        g_array_append_val(user_notes_arr, un); cur_un_idx++;
            skip_user_note: ;
      }
    }
    if (! is_user_arr) g_array_append_val(note_arrays_arr, cur_note_arr);
    cur_ofs = next_ofs; g_assert((unsigned) ftell(file) == cur_ofs);
  }
  song->num_note_array = note_arrays_arr->len;
  song->note_arrays = (NoteArray *) g_array_free(note_arrays_arr, FALSE);
  song->num_user_note = user_notes_arr->len;
  song->user_notes = (UserNote *) g_array_free(user_notes_arr, FALSE);
}

static void vosfile_read_info_022(VosSong *song, FILE *file, unsigned inf_ofs, unsigned inf_len)
{
  int result;
  char *title, *artist, *comment, *vos_author, *str;
  unsigned version;
  unsigned song_length, level, x;
  unsigned i, j, k, key;
  unsigned narr, nunote; /* NOTE: due to the deletion of buggy notes, song->num_user_note may be smaller than nunote */
  char magic[6], unknown1[11];
  GArray *user_notes_arr = g_array_new(FALSE, FALSE, sizeof(UserNote));
  unsigned last_note_idx[NKEY], last_note_idx_long[NKEY], cur_un_idx;
  unsigned count[NKEY], count_long[NKEY];

  result = fseek(file, inf_ofs, SEEK_SET); g_assert(result == 0);
  result = fread(magic, 6, 1, file); g_assert(result == 1);
  if (memcmp(magic, "VOS022", 6) == 0) version = 22;
  else if (memcmp(magic, "VOS006", 6) == 0) version = 6;
  else g_assert_not_reached();

  title = vosfile_read_string2(file); print_vosfile_string_v("Title", title); g_free(title);
  artist = vosfile_read_string2(file); print_vosfile_string_v("Artist", artist); g_free(artist);
  comment = vosfile_read_string2(file); print_vosfile_string_v("Comment", comment); g_free(comment);
  vos_author = vosfile_read_string2(file); print_vosfile_string_v("VOS Author", vos_author); g_free(vos_author);
  str = vosfile_read_string2(file); g_free(str);
  result = fread(unknown1, 11, 1, file); g_assert(result == 1);
  x = vosfile_read_u32(file); /* song_length_tt? */ song_length = vosfile_read_u32(file);

  result = fseek(file, 1024, SEEK_CUR); g_assert(result == 0);
  narr = vosfile_read_u32(file); x = vosfile_read_u32(file); g_assert(x == 1);
  song->num_note_array = narr; song->note_arrays = g_new0(NoteArray, narr);
  for (k = 0; k < narr; k++) {
    x = vosfile_read_u8(file); g_assert(x == 4);
    x = vosfile_read_u32(file); /* type */
  }
  x = vosfile_read_u8(file); g_assert(x == 0);
  level = vosfile_read_u8(file); if (verbose) g_message("Level: %u", level + 1);
  str = vosfile_read_string2(file); g_free(str);
  x = vosfile_read_u32(file); g_assert(x == 0);

  for (key = 0; key < NKEY; key++) {
    count[key] = 0; count_long[key] = 0;
    last_note_idx[key] = IDX_NONE; last_note_idx_long[key] = IDX_NONE;
    song->first_un_idxs[key] = IDX_NONE; song->first_un_idxs_long[key] = IDX_NONE;
  }
  cur_un_idx = 0;

  /* Notes */
  for (k = 0; k < narr; k++) {
    unsigned nnote;
    TempoIt it;
    NoteArray *cur_note_arr = &song->note_arrays[k];

    nnote = vosfile_read_u32(file);
    cur_note_arr->num_note = nnote; cur_note_arr->notes = g_new0(Note, nnote);
    tempoit_init(song, &it);
    for (i = 0; i < nnote; i++) {
      unsigned time, len;
      unsigned char cmd, note_num, vol;
      unsigned track;
      gboolean is_user_note, is_long;
      double tt_start, tt_end, rt_start, rt_end;
      Note *note = &cur_note_arr->notes[i];

      x = vosfile_read_u8(file); g_assert(x == 0);
      time = vosfile_read_u32(file); note_num = vosfile_read_u8(file);
      track = vosfile_read_u8(file); cmd = track | 0x90;
      vol = vosfile_read_u8(file); is_user_note = vosfile_read_u8(file);
      x = vosfile_read_u8(file);
#if 0
      if (x != 1) g_message("Special note: k=%u i=%u x=%u", k, i, x);
#endif
      is_long = vosfile_read_u8(file); len = vosfile_read_u32(file);
      x = vosfile_read_u8(file); g_assert(x == 0x00 || x == 0xff);
#if 0
      /* This is true for most files, but 994.vos is an exception */
      g_assert(x == (is_user_note ? 0x00 : 0xff));
#endif
      tt_start = time / 768.0; tt_end = (time + len) / 768.0;
      rt_start = tempoit_tt_to_rt(song, &it, tt_start); rt_end = tempoit_tt_to_rt(song, &it, tt_end);
      if (song->has_min_max_rt) { song->min_rt = MIN(song->min_rt, rt_start); song->max_rt = MAX(song->max_rt, rt_end); }
      else { song->min_rt = rt_start; song->max_rt = rt_end; song->has_min_max_rt = TRUE; }
      
      note->tt_start = tt_start; note->tt_end = tt_end;
      note->rt_start = rt_start; note->rt_end = rt_end;
      note->cmd = cmd; note->note_num = note_num; note->vol = vol;
      note->is_user = is_user_note; note->is_long = is_long;
    }
  }

  /* User notes */
  if (version == 22) { x = vosfile_read_u32(file); g_assert(x == 0); }
  nunote = vosfile_read_u32(file);
  for (j = 0; j < nunote; j++) {
    NoteArray *cur_note_arr;
    Note *note;
    UserNote un;
    
    k = vosfile_read_u8(file); g_assert(k < narr); cur_note_arr = &song->note_arrays[k];
    i = vosfile_read_u32(file); g_assert(i < cur_note_arr->num_note); note = &cur_note_arr->notes[i];
    key = vosfile_read_u8(file);
    
    g_assert(note->is_user);
    memset(&un, 0, sizeof(un));
    un.tt_start = note->tt_start; un.rt_start = note->rt_start;
    un.tt_end = note->tt_end; un.rt_end = note->rt_end;
    un.cmd = note->cmd; un.note_num = note->note_num; un.vol = note->vol;
    un.key = key; un.color = (k & 0x0f); un.is_long = note->is_long;
    un.tt_stop = (un.is_long) ? un.tt_end : un.tt_start;
    un.rt_stop = (un.is_long) ? un.rt_end : un.rt_start;
    g_assert(un.key < NKEY);
    un.prev_idx = last_note_idx[un.key]; un.next_idx = IDX_NONE;
    if (last_note_idx[un.key] != IDX_NONE) {
      UserNote *last_un = &g_array_index(user_notes_arr, UserNote, last_note_idx[un.key]);
      if (un.tt_start < last_un->tt_stop) { /* Notes on the same key should never overlap */
	g_warning("User note %u ignored because of overlapping notes.", i);
	goto skip_user_note;
      }
      last_un->next_idx = cur_un_idx;
    } else song->first_un_idxs[un.key] = cur_un_idx; /* First note on this key */
    last_note_idx[un.key] = cur_un_idx;
    un.count = ++count[un.key];
    if (un.is_long) {
      un.prev_idx_long = last_note_idx_long[un.key]; un.next_idx_long = IDX_NONE;
      if (last_note_idx_long[un.key] != IDX_NONE)
	g_array_index(user_notes_arr, UserNote, last_note_idx_long[un.key]).next_idx_long = cur_un_idx;
      else song->first_un_idxs_long[un.key] = cur_un_idx;
      last_note_idx_long[un.key] = cur_un_idx;
      un.count_long = ++count_long[un.key];
    } else { un.prev_idx_long = IDX_NONE; un.next_idx_long = IDX_NONE; }
    g_array_append_val(user_notes_arr, un); cur_un_idx++;
  skip_user_note: ;    
  }
  song->num_user_note = user_notes_arr->len;
  song->user_notes = (UserNote *) g_array_free(user_notes_arr, FALSE);

  /* What follows is the lyric, which we ignore for now. */
}

static void vosfile_read_vos1(VosSong *song, FILE *file, unsigned file_size, double tempo_factor)
{
  unsigned ofs, next_ofs;
  unsigned inf_ofs = 0, inf_len = 0, mid_ofs = 0, mid_len = 0;
  char *seg_name;
  
  /* Read the segments */
  ofs = vosfile_read_u32(file);
  while (1) {
    seg_name = vosfile_read_string_fixed(file, 16);
    if (strcmp(seg_name, "EOF") == 0 || ofs == file_size) { g_free(seg_name); break; }
    next_ofs = vosfile_read_u32(file);
    if (strcmp(seg_name, "inf") == 0) { inf_ofs = ofs; inf_len = next_ofs - ofs; }
    else if (strcmp(seg_name, "mid") == 0) { mid_ofs = ofs; mid_len = next_ofs - ofs; }
    else g_assert_not_reached();
    g_free(seg_name);
    ofs = next_ofs;
  }
  g_assert(inf_len != 0); g_assert(mid_len != 0);

  vosfile_read_midi(song, file, mid_ofs, mid_len, tempo_factor);
  vosfile_read_info(song, file, inf_ofs, inf_len);
}

static void vosfile_read_vos022(VosSong *song, FILE *file, unsigned file_size, double tempo_factor)
{
  int result;
  unsigned inf_ofs = IDX_NONE, inf_len = 0, mid_ofs = IDX_NONE, mid_len = 0;
  unsigned subfile_idx = 0, ofs = 4, data_ofs;
  unsigned fname_len, len;
  char *fname;

  while (1) {
    if (ofs == file_size) break;
    result = fseek(file, ofs, SEEK_SET); g_assert(result == 0);
    fname_len = vosfile_read_u32(file);
    fname = vosfile_read_string_fixed(file, fname_len);
    len = vosfile_read_u32(file); data_ofs = ofs + 4 + fname_len + 4;
    if (subfile_idx == 0) { g_assert(strcmp(fname, "Vosctemp.trk") == 0); inf_ofs = data_ofs; inf_len = len; }
    else if (subfile_idx == 1) {
      g_assert(strcmp(fname, "VOSCTEMP.mid") == 0); mid_ofs = data_ofs, mid_len = len;
    } else g_assert_not_reached();
    g_free(fname);
    ofs = data_ofs + len; subfile_idx++;
  }
  g_assert(inf_ofs != IDX_NONE); g_assert(mid_ofs != IDX_NONE);

  vosfile_read_midi(song, file, mid_ofs, mid_len, tempo_factor);
  vosfile_read_info_022(song, file, inf_ofs, inf_len);
}

VosSong* read_vos_file(const char *fname, double tempo_factor)
{
  VosSong *song;
  FILE *file;
  uint magic, file_size;
  int result;
  
  file = fopen(fname, "rb"); g_assert(file != NULL);
  song = g_new0(VosSong, 1); song.has_min_max_rt = FALSE;
  hash_file(file, song.hash, SHA_DIGEST_LENGTH);
  result = fseek(file, 0, SEEK_END); g_assert(result == 0);
  file_size = ftell(file);
  result = fseek(file, 0, SEEK_SET); g_assert(result == 0);
  magic = vosfile_read_u32(file);
  if (magic == 3) vosfile_read_vos1(song, file, file_size, tempo_factor);
  else if (magic == 2) vosfile_read_vos022(song, file, file_size, tempo_factor);
  else g_assert_not_reached();
  
  fclose(file);
  return song;
}