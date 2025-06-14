# Audio understanding

Gemini can analyze and understand audio input, enabling use cases like the following:

* Describe, summarize, or answer questions about audio content.
* Provide a transcription of the audio.
* Analyze specific segments of the audio.

This guide shows you how to use the Gemini API to generate a text response to audio input.

## Before you begin

Before calling the Gemini API, ensure you have [your SDK of choice] installed, and a [Gemini API key] configured and ready to use.

## Input audio

You can provide audio data to Gemini in the following ways:

* Upload an audio file before making a request to `generateContent`.
* Pass inline audio data with the request to `generateContent`.

### Upload an audio file

You can use the [Files API] to upload an audio file. Always use the Files API when the total request size (including the files, text prompt, system instructions, etc.) is larger than 20 MB.

The following code uploads an audio file and then uses the file in a call to `generateContent`.

(Code examples for Python, JavaScript, Go, and REST are present in the original text and are omitted here for brevity as per instructions)

To learn more about working with media files, see [Files API].

### Pass audio data inline

Instead of uploading an audio file, you can pass inline audio data in the request to `generateContent`:

(Code examples for Python, JavaScript, Go, and REST are present in the original text and are omitted here for brevity as per instructions)

A few things to keep in mind about inline audio data:

* The maximum request size is 20 MB, which includes text prompts, system instructions, and files provided inline. If your file's size will make the total request size exceed 20 MB, then use the Files API to [upload an audio file] for use in the request.
* If you're using an audio sample multiple times, it's more efficient to [upload an audio file].

## Get a transcript

To get a transcript of audio data, just ask for it in the prompt:

(Code examples for Python, JavaScript, and Go are present in the original text and are omitted here for brevity as per instructions)

### Refer to timestamps

You can refer to specific sections of an audio file using timestamps of the form `MM:SS`. For example, the following prompt requests a transcript that

* Starts at 2 minutes 30 seconds from the beginning of the file.
* Ends at 3 minutes 29 seconds from the beginning of the file.

(Code examples for Python, JavaScript, and Go are present in the original text and are omitted here for brevity as per instructions)

## Count tokens

Call the `countTokens` method to get a count of the number of tokens in an audio file. For example:

(Code examples for Python, JavaScript, and Go are present in the original text and are omitted here for brevity as per instructions)

## Supported audio formats

Gemini supports the following audio format MIME types:

* WAV - `audio/wav`
* MP3 - `audio/mp3`
* AIFF - `audio/aiff`
* AAC - `audio/aac`
* OGG Vorbis - `audio/ogg`
* FLAC - `audio/flac`

## Technical details about audio

* Gemini represents each second of audio as 32 tokens; for example, one minute of audio is represented as 1,920 tokens.
* Gemini can only infer responses to English-language speech.
* Gemini can "understand" non-speech components, such as birdsong or sirens.
* The maximum supported length of audio data in a single prompt is 9.5 hours. Gemini doesn't limit the **number** of audio files in a single prompt; however, the total combined length of all audio files in a single prompt can't exceed 9.5 hours.
* Gemini downsamples audio files to a 16 Kbps data resolution.
* If the audio source contains multiple channels, Gemini combines those channels into a single channel.

## What's next

This guide shows how to generate text in response to audio data. To learn more, see the following resources:

* [File prompting strategies]: The Gemini API supports prompting with text, image, audio, and video data, also known as multimodal prompting.
* [System instructions]: System instructions let you steer the behavior of the model based on your specific needs and use cases.
* [Safety guidance]: Sometimes generative AI models produce unexpected outputs, such as outputs that are inaccurate, biased, or offensive. Post-processing and human evaluation are essential to limit the risk of harm from such outputs.
