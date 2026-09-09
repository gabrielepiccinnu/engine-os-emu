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
//     insmod snd-combined.ko id=NH08 name="NH08" channels=2 rate=48000

#include <linux/init.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/math64.h>
#include <linux/timer.h>
#include <sound/core.h>
#include <sound/initval.h>
#include <sound/pcm.h>
#include <sound/rawmidi.h>

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Virtual combined PCM and MIDI card");

static char *id = "COMBINED";
static char *name = "Combined";
static int channels = 2;
static int rate = 48000;
module_param(id, charp, 0444);
module_param(name, charp, 0444);
module_param(channels, int, 0444);
module_param(rate, int, 0444);

static struct platform_device *combined_pdev;

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
 * device manager follows back to a card number. It moves no bytes. */
static int combined_midi_open(struct snd_rawmidi_substream *s) { return 0; }
static int combined_midi_close(struct snd_rawmidi_substream *s) { return 0; }
static void combined_midi_trigger(struct snd_rawmidi_substream *s, int up) { }

static const struct snd_rawmidi_ops combined_midi_ops = {
	.open = combined_midi_open,
	.close = combined_midi_close,
	.trigger = combined_midi_trigger,
};

static int combined_probe(struct platform_device *pdev)
{
	struct snd_card *card;
	struct snd_pcm *pcm;
	struct snd_rawmidi *rmidi;
	int err;

	err = snd_card_new(&pdev->dev, SNDRV_DEFAULT_IDX1, id, THIS_MODULE, 0, &card);
	if (err < 0)
		return err;

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

	err = snd_rawmidi_new(card, name, 0, 1, 1, &rmidi);
	if (err < 0)
		goto fail;
	strscpy(rmidi->name, name, sizeof(rmidi->name));
	rmidi->info_flags = SNDRV_RAWMIDI_INFO_OUTPUT | SNDRV_RAWMIDI_INFO_INPUT |
			    SNDRV_RAWMIDI_INFO_DUPLEX;
	snd_rawmidi_set_ops(rmidi, SNDRV_RAWMIDI_STREAM_OUTPUT, &combined_midi_ops);
	snd_rawmidi_set_ops(rmidi, SNDRV_RAWMIDI_STREAM_INPUT, &combined_midi_ops);

	err = snd_card_register(card);
	if (err < 0)
		goto fail;

	platform_set_drvdata(pdev, card);
	return 0;

fail:
	snd_card_free(card);
	return err;
}

static int combined_remove(struct platform_device *pdev)
{
	snd_card_free(platform_get_drvdata(pdev));
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
