# imasimgbot Quick Start Guide

This covers the basics to get imasimgbot up and running, in addition to some other basic features. You should consult [structure.md](./structure.md) for more details. Consult [README.md](../README.md) for installation instructions.

Before doing anything else, create the data directory in the root of the project (where the scripts are). Then in that directory, create idols.txt. Append this file with the idols that should post on a schedule.

## Creating and authenticating an idol

Once the data directory is created, you can create *idols*, which for our purposes is a folder of images and some credentials for a Bluesky account where the images are posted to.

In the data directory, create a folder named whatever you'd like. The name of this folder is the name of the *idol*.

To create credentials for just this one idol, run `./idolbot.sh <idol> login --interactive`. If you have multiple idols that need credentials, you can instead run `./imasimgbot.sh init-secrets` which will cause all idols without credentials to prompt for them.

Once authenticated, this idol can already repost image posts by other bots, but to post its own you'll need to add them. But to add images, you'll need to set up an event.

## Creating the regular event

imasimgbot works with events, which are linked to files that contain a list of image entries for that event. The event used when no other events are in progress is referred to as the `regular` event.

To get started, create a folder called `images` in the idol folder and open it. Then create `regular.txt`. This file will contain all your images.

## Adding images

An image entry consists of an image and metadata, or consist of any number of subentries (which contain images and metadata). This image entry is then referenced by an event, which will post it.

Create a folder in the images folder, you can name it anything you'd like. In the created folder, copy an image and rename the file name to `image` (but keep the file extension). This image can be a PNG, JPEG, or even an MP4 file for video. Other file types aren't tested and probably won't work with Bluesky. This image doesn't need to comply with their size limits; the bot will automatically compress and resize the posted image if needed (it does not modify the original file).

Next create a file called `info.txt`. This file contains important metadata on the image entry. An example of this file looks like:

```
imgtype=png
alt=Alt text goes here
otheridols=
```

`imgtype` should be changed to the file extension of the image. `alt` is the alt text of the posted image. Idols listed in `otheridols` will repost this image when this entry is posted. You can specify multiple idols in `otheridols` by separating them with commas.

### Subentries

If an entry is to contain subentries, do not copy the image in the image entry folder. Instead, just create `info.txt` with the only line being `subentries=1`. To create a subentry, just create a folder in the image entry folder. The structure of subentries is identical to regular entries, however you cannot have nested subentries. Subentries are found much like how events are; create a file named subentries.txt in the main image entry folder (not any subentries) and list the folder names of the subentries you want to post.

## Verifiying

The `imgverify.sh` script lets you test your current configuration for errors. It is a good idea to run this after adding new image entries. Simply run it, and it will inform you about what is broken. By default it does not thoroughly check images, to do that, pass the `--scan-images` parameter. `imgverify.sh` also has options to build and repair the image cache, which are out of scope for this guide.

## Posting!

After you've added a few image entries, you should be able to post to Bluesky. To post an image manually, you can run `./idolbot.sh <idol> post` .

Once you've verified everything is working correctly, you can enable the bot to run automatically by continuing to follow the instructions in [README.md](../README.md).
