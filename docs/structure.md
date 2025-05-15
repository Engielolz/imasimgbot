## Folder structure

* 📂 data
  
  * 📄 idols.txt
  
  * 📂 \<idol\>
    
    * 📄 idol.txt
    
    * 📄 recents.txt
    
    * 📄 \<event\>-recents.txt (list of recently used images, cleared when all used)
    
    * 📄 secrets.env (auth)
    
    * 📂images
      
      * 📄 birthday.txt
      
      * 📄 fools.txt
      
      * 📄 halloween.txt
      
      * 📄 regular.txt
      
      * 📂\<user\>.\<imagename\>
        
        * 📄 image.\<imgtype\>
        
        * 📄 info.txt

## idols.txt

List of idols that should post. Must match directories in data/

## idol.txt

Contains configuration data. Has the birthday, image override information, the size of the global recents queue, the post interval and image caching options.

## recents.txt

This is the global (for the idol) recents queue. Instead of resetting when its full, it instead rotates a list of the most recently used images (24 by default, but can be configured in idol.txt)

## \<event\>-recents.txt

Contains list of all used image entries. Cleared when all images have been used, to start the cycle anew.

## \<event\>.txt

Event files like regular.txt just contain a list of directory entries that contain the images and metadata relevant to the event.

## image.\<imgtype\>

The image itself. \<imgtype\> is just the file extension. It must match the one specified in info.txt or it won't work.

## info.txt

This file is inside of every image entry, and contains important metadata, namely the imgtype, alt text, post text, self-labels and any other idols that are in the image. All but imgtype may be omitted, but I recommend you just leave them blank. Multiple idols and self-labels may be specified in otheridols and selflabel respectively by separating them with commas without spaces.

### example

```
imgtype=png
alt=Haruka Amami, Chihaya Kisaragi and Miki Hoshii
otheridols=chihaya,miki
```
