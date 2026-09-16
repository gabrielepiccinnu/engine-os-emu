// Virtual ALSA card carrying playback, capture and MIDI at once.
//
// WHY THIS EXISTS
// Engine locates its audio through airDeviceManager, whose Linux backend is
// ALSACombinedDevice: it wants one card that is both a playback and a capture
// device, and it reaches it from the card number that a MIDI client reports.
// On the real unit that card is the control surface plus codec, a single
// composite device. Under emulation there is nothing of the sort, and no
// in-tree driver offers PCM and rawmidi on one card: snd-aloop has no MIDI,
// snd-virmidi has no PCM. Engine therefore fails with
//   client id: N - card number unavailable
//   Failed to fetch the audio device ""
// This module supplies the missing shape. The PCM is driven by a timer and
// carries no samples, which is enough to answer whether the device manager
// accepts the card. Real audio would come from a USB interface presenting the
// same shape, which is the point of the exercise.
//
// THE CONTROL SURFACE IS A SECOND CARD, AND A CROSSOVER
// On the real unit the buttons, pads and encoders talk MIDI over a UART, and
// that port is a separate ALSA card whose client and port are both called
// "Control Surface" (the firmware updater names it as its flash target,
// "Control Surface:Control Surface 16:0"). Engine binds the product's
// assignment file to that name, so the card here carries it too. Its rawmidi
// device 0 is the one Engine opens. Device 1 is the other end of the cable:
// whatever is written to it arrives as input on device 0. That turns the
// product's own assignment file into a way of pressing its buttons:
//
//     amidi -p hw:Surface,1 -S "9f 01 7f"    # Note On, channel 16, note 1: LOAD, deck 1
//
// Device 1 has no input side on purpose. Engine opens every port it can
// read and pairs an output with whichever input answers its identity
// request first; an input on the inject device would get the request echoed
// into it and win that race, and the assignment would then listen to the
// wrong port. What Engine writes to the surface (LED colours, VU meters,
// SysEx) is readable instead from
//
//     /proc/asound/Surface/monitor
//
// a blocking byte stream that is not a MIDI port, so Engine cannot see it.
// debug=1 also prints every byte to the kernel log.
//
// Engine binds nothing to a port until it has answered a MIDI Identity
// Request. Its KnownDevices.xml wants the reply of the real surface,
//   7E ?? 06 02 00 01 3F 3F ?? ?? ?? ?? ?? ?? 00
// inMusic's manufacturer id and family 3F, and it asks only three times in
// the first half minute. So the surface card answers that request itself,
// on the spot, and Engine loads "NH08 Controller" as if the buttons were there.
//
//     insmod snd-combined.ko id=NH08 name="NH08" channels=16 rate=48000

#include <linux/init.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/math64.h>
#include <linux/timer.h>
#include <linux/kfifo.h>
#include <linux/poll.h>
#include <linux/wait.h>
#include <sound/core.h>
#include <sound/info.h>
#include <sound/initval.h>
#include <sound/pcm.h>
#include <sound/rawmidi.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Virtual combined PCM and MIDI card");

static char *id = "COMBINED";
static char *name = "Combined";
static int channels = 2;
static int rate = 48000;
static char *surface = "Control Surface";
static bool debug;
static char *identity = "00 01 01 00 00 31";
module_param(id, charp, 0444);
module_param(name, charp, 0444);
module_param(channels, int, 0444);
module_param(rate, int, 0444);
module_param(surface, charp, 0444);
MODULE_PARM_DESC(surface, "name of the control surface MIDI card, empty for none");
module_param(debug, bool, 0644);
MODULE_PARM_DESC(debug, "log every byte crossing between the two MIDI devices");
module_param(identity, charp, 0444);
MODULE_PARM_DESC(identity, "the six free bytes of the identity reply; the last four are the firmware version");

static struct platform_device *combined_pdev;

struct combined_cards {
	struct snd_card *audio;
	struct snd_card *surface;
};

struct combined_stream {
	struct snd_pcm_substream *substream;
	struct timer_list timer;
	unsigned int period_bytes;
	unsigned int buffer_bytes;
	unsigned int pos;
	unsigned int period_jiffies;
	bool running;
};

static void combined_timer(struct timer_list *t)
{
	struct combined_stream *s = from_timer(s, t, timer);

	if (!s->running)
		return;
	s->pos += s->period_bytes;
	if (s->pos >= s->buffer_bytes)
		s->pos -= s->buffer_bytes;
	mod_timer(&s->timer, jiffies + s->period_jiffies);
	snd_pcm_period_elapsed(s->substream);
}

static struct snd_pcm_hardware combined_hw = {
	.info = SNDRV_PCM_INFO_INTERLEAVED | SNDRV_PCM_INFO_BLOCK_TRANSFER |
		SNDRV_PCM_INFO_MMAP | SNDRV_PCM_INFO_MMAP_VALID,
	.formats = SNDRV_PCM_FMTBIT_S16_LE | SNDRV_PCM_FMTBIT_S32_LE,
	.rates = SNDRV_PCM_RATE_44100 | SNDRV_PCM_RATE_48000 |
		 SNDRV_PCM_RATE_88200 | SNDRV_PCM_RATE_96000,
	.rate_min = 44100,
	.rate_max = 96000,
	.channels_min = 1,
	.channels_max = 32,
	.buffer_bytes_max = 4 * 1024 * 1024,
	.period_bytes_min = 64,
	.period_bytes_max = 1024 * 1024,
	.periods_min = 2,
	.periods_max = 32,
};

static int combined_open(struct snd_pcm_substream *substream)
{
	struct combined_stream *s;

	s = kzalloc(sizeof(*s), GFP_KERNEL);
	if (!s)
		return -ENOMEM;
	s->substream = substream;
	timer_setup(&s->timer, combined_timer, 0);
	substream->runtime->hw = combined_hw;
	/* Engine validates the channel count and the rate of the card it opens,
	 * and rejects it outright when either is not what the product expects,
	 * so both are parameters: they are what an experiment varies. */
	/* channels=0 advertises the whole 1..8 range instead, which turns the
	 * card into a probe: whatever Engine settles on is what the product
	 * requires, readable afterwards in the substream's hw_params. */
	if (channels > 0) {
		substream->runtime->hw.channels_min = channels;
		substream->runtime->hw.channels_max = channels;
	}
	substream->runtime->hw.rate_min = rate;
	substream->runtime->hw.rate_max = rate;
	substream->runtime->hw.rates = snd_pcm_rate_to_rate_bit(rate);
	substream->runtime->private_data = s;
	return 0;
}

static int combined_close(struct snd_pcm_substream *substream)
{
	struct combined_stream *s = substream->runtime->private_data;

	if (s) {
		del_timer_sync(&s->timer);
		kfree(s);
	}
	return 0;
}

static int combined_prepare(struct snd_pcm_substream *substream)
{
	struct snd_pcm_runtime *runtime = substream->runtime;
	struct combined_stream *s = runtime->private_data;
	unsigned int period_us;

	s->buffer_bytes = snd_pcm_lib_buffer_bytes(substream);
	s->period_bytes = snd_pcm_lib_period_bytes(substream);
	s->pos = 0;
	/* div_u64, not "/": a 64 bit division on ARM32 pulls in __aeabi_uldivmod,
	 * which the kernel does not export to modules. */
	period_us = (unsigned int)div_u64((u64)runtime->period_size * 1000000,
					  runtime->rate);
	s->period_jiffies = usecs_to_jiffies(period_us);
	if (!s->period_jiffies)
		s->period_jiffies = 1;
	return 0;
}

static int combined_trigger(struct snd_pcm_substream *substream, int cmd)
{
	struct combined_stream *s = substream->runtime->private_data;

	switch (cmd) {
	case SNDRV_PCM_TRIGGER_START:
		s->running = true;
		mod_timer(&s->timer, jiffies + s->period_jiffies);
		return 0;
	case SNDRV_PCM_TRIGGER_STOP:
		s->running = false;
		del_timer(&s->timer);
		return 0;
	}
	return -EINVAL;
}

static snd_pcm_uframes_t combined_pointer(struct snd_pcm_substream *substream)
{
	struct combined_stream *s = substream->runtime->private_data;

	return bytes_to_frames(substream->runtime, s->pos);
}

static const struct snd_pcm_ops combined_ops = {
	.open = combined_open,
	.close = combined_close,
	.prepare = combined_prepare,
	.trigger = combined_trigger,
	.pointer = combined_pointer,
};

/* The MIDI side exists so the card owns a sequencer client: that is what the
 * device manager follows back to a card number. On top of that the two
 * rawmidi devices are wired to each other: the output of either is the
 * input of the other, so device 1 can play the control surface. */
struct combined_midi {
	spinlock_t lock;
	struct snd_rawmidi_substream *input[2];	/* input substream per device */
	bool input_running[2];
	bool answer_identity;			/* the surface card: reply to 7E xx 06 01 */
	unsigned char sysex[16];		/* the SysEx being written to device 0 */
	int sysex_len;				/* -1 outside a SysEx */
	/* everything Engine writes to device 0, for /proc/asound/<card>/monitor */
	DECLARE_KFIFO(monitor, unsigned char, 4096);
	wait_queue_head_t monitor_wait;
	bool monitor_open;
};

/* Universal Identity Reply: inMusic (00 01 3F), family 3F, then six bytes
 * Engine's pattern leaves free. It reads the last four as the surface's
 * firmware version and wants it EQUAL to the one it ships in
 * /usr/Engine/Firmware/<product> Controller/firmware.json, 1.0.0.49 for
 * NH08: anything else, newer included, is "version mismatch; starting
 * updater" and Engine quits into the firmware updater. Another firmware
 * image needs the identity= parameter set to its version. */
static unsigned char identity_reply[] = {
	0xf0, 0x7e, 0x00, 0x06, 0x02, 0x00, 0x01, 0x3f, 0x3f,
	0x00, 0x01, 0x01, 0x00, 0x00, 0x31, 0x00, 0xf7
};

static void combined_parse_identity(void)
{
	const char *p = identity;
	int i, v;

	for (i = 0; i < 6; i++) {
		while (*p == ' ')
			p++;
		if (sscanf(p, "%2x", &v) != 1)
			return;
		identity_reply[9 + i] = v & 0x7f;
		while (*p && *p != ' ')
			p++;
	}
}

/* Watches the bytes Engine writes to the surface for an Identity Request
 * and, on its F7, feeds the reply back as surface input. Called with the
 * crossover lock held. */
static void combined_midi_identity(struct combined_midi *m, const unsigned char *buf, int n)
{
	int i;

	for (i = 0; i < n; i++) {
		unsigned char c = buf[i];

		if (c == 0xf0) {
			m->sysex_len = 0;
			continue;
		}
		if (m->sysex_len < 0)
			continue;
		if (c != 0xf7) {
			if (m->sysex_len < (int)sizeof(m->sysex))
				m->sysex[m->sysex_len] = c;
			m->sysex_len++;
			continue;
		}
		if (m->sysex_len == 4 && m->sysex[0] == 0x7e &&
		    m->sysex[2] == 0x06 && m->sysex[3] == 0x01 &&
		    m->input_running[0] && m->input[0]) {
			if (debug)
				pr_info("midi surface> identity reply\n");
			snd_rawmidi_receive(m->input[0], identity_reply, sizeof(identity_reply));
		}
		m->sysex_len = -1;
	}
}

static int combined_midi_open(struct snd_rawmidi_substream *s) { return 0; }
static int combined_midi_close(struct snd_rawmidi_substream *s) { return 0; }

static int combined_midi_input_open(struct snd_rawmidi_substream *s)
{
	struct combined_midi *m = s->rmidi->private_data;
	unsigned long flags;

	spin_lock_irqsave(&m->lock, flags);
	m->input[s->rmidi->device] = s;
	spin_unlock_irqrestore(&m->lock, flags);
	return 0;
}

static int combined_midi_input_close(struct snd_rawmidi_substream *s)
{
	struct combined_midi *m = s->rmidi->private_data;
	unsigned long flags;

	spin_lock_irqsave(&m->lock, flags);
	m->input[s->rmidi->device] = NULL;
	m->input_running[s->rmidi->device] = false;
	spin_unlock_irqrestore(&m->lock, flags);
	return 0;
}

static void combined_midi_input_trigger(struct snd_rawmidi_substream *s, int up)
{
	struct combined_midi *m = s->rmidi->private_data;
	unsigned long flags;

	spin_lock_irqsave(&m->lock, flags);
	m->input_running[s->rmidi->device] = up;
	spin_unlock_irqrestore(&m->lock, flags);
}

/* Output of one device is delivered straight into the input of the other.
 * Bytes written while the far side is not reading are dropped, as they would
 * be on a cable with nothing listening. */
static void combined_midi_output_trigger(struct snd_rawmidi_substream *s, int up)
{
	struct combined_midi *m = s->rmidi->private_data;
	int peer = 1 - s->rmidi->device;
	unsigned char buf[64];
	unsigned long flags;
	int n;

	if (!up)
		return;
	for (;;) {
		n = snd_rawmidi_transmit(s, buf, sizeof(buf));
		if (n <= 0)
			break;
		if (debug)
			print_hex_dump(KERN_INFO, s->rmidi->device ? "midi inject> " : "midi engine> ",
				       DUMP_PREFIX_NONE, 32, 1, buf, n, false);
		spin_lock_irqsave(&m->lock, flags);
		if (m->input_running[peer] && m->input[peer])
			snd_rawmidi_receive(m->input[peer], buf, n);
		if (m->answer_identity && s->rmidi->device == 0)
			combined_midi_identity(m, buf, n);
		if (m->monitor_open && s->rmidi->device == 0) {
			/* a reader that fell behind loses the oldest bytes, not the newest */
			while (kfifo_avail(&m->monitor) < n)
				kfifo_skip(&m->monitor);
			kfifo_in(&m->monitor, buf, n);
		}
		spin_unlock_irqrestore(&m->lock, flags);
		if (m->monitor_open && s->rmidi->device == 0)
			wake_up_interruptible(&m->monitor_wait);
	}
}

/* The monitor: what Engine sends to the surface, as a stream. One reader at a
 * time, blocking, so `cat` on it behaves like a serial port. */
static int combined_monitor_open(struct snd_info_entry *entry, unsigned short mode, void **file_private_data)
{
	struct combined_midi *m = entry->private_data;
	unsigned long flags;

	spin_lock_irqsave(&m->lock, flags);
	if (m->monitor_open) {
		spin_unlock_irqrestore(&m->lock, flags);
		return -EBUSY;
	}
	kfifo_reset(&m->monitor);
	m->monitor_open = true;
	spin_unlock_irqrestore(&m->lock, flags);
	return 0;
}

static int combined_monitor_release(struct snd_info_entry *entry, unsigned short mode, void *file_private_data)
{
	struct combined_midi *m = entry->private_data;
	unsigned long flags;

	spin_lock_irqsave(&m->lock, flags);
	m->monitor_open = false;
	spin_unlock_irqrestore(&m->lock, flags);
	return 0;
}

static ssize_t combined_monitor_read(struct snd_info_entry *entry, void *file_private_data,
				     struct file *file, char __user *buf, size_t count, loff_t pos)
{
	struct combined_midi *m = entry->private_data;
	unsigned int copied;
	int err;

	if (kfifo_is_empty(&m->monitor)) {
		if (file->f_flags & O_NONBLOCK)
			return -EAGAIN;
		err = wait_event_interruptible(m->monitor_wait, !kfifo_is_empty(&m->monitor));
		if (err)
			return err;
	}
	err = kfifo_to_user(&m->monitor, buf, count, &copied);
	return err ? err : copied;
}

static __poll_t combined_monitor_poll(struct snd_info_entry *entry, void *file_private_data,
				      struct file *file, poll_table *wait)
{
	struct combined_midi *m = entry->private_data;

	poll_wait(file, &m->monitor_wait, wait);
	return kfifo_is_empty(&m->monitor) ? 0 : (EPOLLIN | EPOLLRDNORM);
}

static const struct snd_info_entry_ops combined_monitor_ops = {
	.open = combined_monitor_open,
	.release = combined_monitor_release,
	.read = combined_monitor_read,
	.poll = combined_monitor_poll,
};

static int combined_monitor_new(struct snd_card *card, struct combined_midi *m)
{
	struct snd_info_entry *entry;

	INIT_KFIFO(m->monitor);
	init_waitqueue_head(&m->monitor_wait);
	entry = snd_info_create_card_entry(card, "monitor", card->proc_root);
	if (!entry)
		return -ENOMEM;
	entry->content = SNDRV_INFO_CONTENT_DATA;
	entry->private_data = m;
	entry->c.ops = &combined_monitor_ops;
	entry->mode = S_IFREG | 0444;
	/* snd_info clips every read to entry->size before calling ops->read,
	 * and a stream has no size: make it one no reader will reach */
	entry->size = 1UL << 30;
	/* card registration takes care of snd_info_register for its entries */
	return 0;
}

static const struct snd_rawmidi_ops combined_midi_output_ops = {
	.open = combined_midi_open,
	.close = combined_midi_close,
	.trigger = combined_midi_output_trigger,
};

static const struct snd_rawmidi_ops combined_midi_input_ops = {
	.open = combined_midi_input_open,
	.close = combined_midi_input_close,
	.trigger = combined_midi_input_trigger,
};

static int combined_midi_new(struct snd_card *card, struct combined_midi *m,
			     int device, char *label, bool with_input)
{
	struct snd_rawmidi *rmidi;
	int err;

	err = snd_rawmidi_new(card, label, device, 1, with_input ? 1 : 0, &rmidi);
	if (err < 0)
		return err;
	strscpy(rmidi->name, label, sizeof(rmidi->name));
	rmidi->info_flags = SNDRV_RAWMIDI_INFO_OUTPUT;
	if (with_input)
		rmidi->info_flags |= SNDRV_RAWMIDI_INFO_INPUT | SNDRV_RAWMIDI_INFO_DUPLEX;
	rmidi->private_data = m;
	snd_rawmidi_set_ops(rmidi, SNDRV_RAWMIDI_STREAM_OUTPUT, &combined_midi_output_ops);
	if (with_input)
		snd_rawmidi_set_ops(rmidi, SNDRV_RAWMIDI_STREAM_INPUT, &combined_midi_input_ops);
	return 0;
}

static int combined_audio_card(struct platform_device *pdev, struct snd_card **out)
{
	struct snd_card *card;
	struct snd_pcm *pcm;
	struct combined_midi *midi;
	int err;

	err = snd_card_new(&pdev->dev, SNDRV_DEFAULT_IDX1, id, THIS_MODULE,
			   sizeof(*midi), &card);
	if (err < 0)
		return err;
	midi = card->private_data;
	spin_lock_init(&midi->lock);
	midi->sysex_len = -1;

	strscpy(card->driver, "Combined", sizeof(card->driver));
	strscpy(card->shortname, name, sizeof(card->shortname));
	strscpy(card->longname, name, sizeof(card->longname));

	err = snd_pcm_new(card, name, 0, 1, 1, &pcm);
	if (err < 0)
		goto fail;
	snd_pcm_set_ops(pcm, SNDRV_PCM_STREAM_PLAYBACK, &combined_ops);
	snd_pcm_set_ops(pcm, SNDRV_PCM_STREAM_CAPTURE, &combined_ops);
	pcm->private_data = card;
	pcm->info_flags = 0;
	strscpy(pcm->name, name, sizeof(pcm->name));
	snd_pcm_set_managed_buffer_all(pcm, SNDRV_DMA_TYPE_VMALLOC, NULL,
				       0, 4 * 1024 * 1024);

	/* the MIDI client the device manager follows back to this card; it
	 * has no partner, so what is written to it goes nowhere */
	err = combined_midi_new(card, midi, 0, name, true);
	if (err < 0)
		goto fail;

	err = snd_card_register(card);
	if (err < 0)
		goto fail;
	*out = card;
	return 0;

fail:
	snd_card_free(card);
	return err;
}

static int combined_surface_card(struct platform_device *pdev, struct snd_card **out)
{
	struct snd_card *card;
	struct combined_midi *midi;
	char label[64];
	int err;

	err = snd_card_new(&pdev->dev, SNDRV_DEFAULT_IDX1, "Surface", THIS_MODULE,
			   sizeof(*midi), &card);
	if (err < 0)
		return err;
	midi = card->private_data;
	spin_lock_init(&midi->lock);
	midi->answer_identity = true;
	midi->sysex_len = -1;
	combined_parse_identity();

	strscpy(card->driver, "Combined", sizeof(card->driver));
	strscpy(card->shortname, surface, sizeof(card->shortname));
	strscpy(card->longname, surface, sizeof(card->longname));

	/* device 0 carries the surface's own name: it is the one Engine binds */
	err = combined_midi_new(card, midi, 0, surface, true);
	if (err < 0)
		goto fail;
	snprintf(label, sizeof(label), "%s inject", surface);
	err = combined_midi_new(card, midi, 1, label, false);
	if (err < 0)
		goto fail;
	err = combined_monitor_new(card, midi);
	if (err < 0)
		goto fail;

	err = snd_card_register(card);
	if (err < 0)
		goto fail;
	*out = card;
	return 0;

fail:
	snd_card_free(card);
	return err;
}

static int combined_probe(struct platform_device *pdev)
{
	struct combined_cards *cards;
	int err;

	cards = devm_kzalloc(&pdev->dev, sizeof(*cards), GFP_KERNEL);
	if (!cards)
		return -ENOMEM;

	err = combined_audio_card(pdev, &cards->audio);
	if (err < 0)
		return err;
	if (surface && *surface) {
		err = combined_surface_card(pdev, &cards->surface);
		if (err < 0) {
			snd_card_free(cards->audio);
			return err;
		}
	}
	platform_set_drvdata(pdev, cards);
	return 0;
}

static int combined_remove(struct platform_device *pdev)
{
	struct combined_cards *cards = platform_get_drvdata(pdev);

	if (cards->surface)
		snd_card_free(cards->surface);
	snd_card_free(cards->audio);
	return 0;
}

static struct platform_driver combined_driver = {
	.probe = combined_probe,
	.remove = combined_remove,
	.driver = { .name = "snd_combined" },
};

static int __init combined_init(void)
{
	int err = platform_driver_register(&combined_driver);

	if (err < 0)
		return err;
	combined_pdev = platform_device_register_simple("snd_combined", 0, NULL, 0);
	if (IS_ERR(combined_pdev)) {
		platform_driver_unregister(&combined_driver);
		return PTR_ERR(combined_pdev);
	}
	return 0;
}

static void __exit combined_exit(void)
{
	platform_device_unregister(combined_pdev);
	platform_driver_unregister(&combined_driver);
}

module_init(combined_init);
module_exit(combined_exit);
