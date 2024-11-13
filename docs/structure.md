## Folder structure

* 📂 data
  
  * 📄 idols.txt
  
  * 📂 \<idol\>
    
    * 📄 \<event\>-recents.txt (list of recently used images, cleared when all used)
    
    * 📄 secrets.env (auth)
    
    * 📂images
      
      * 📄 fools.txt
      
      * 📄 halloween.txt
      
      * 📄 regular.txt
      
      * 📂\<user\>.\<imagename\>
        
        * 📄 image.\<imgtype\>
        
        * 📄 info.txt

## idols.txt

List of idols that should post. Must match directories in data/

## \<event\>-recents.txt

Contains list of all used image entries. Cleared when all images have been used, to start the cycle anew.

## \<event\>.txt

Event files like regular.txt just contain a list of directory entries that contain the images and metadata relevant to the event.

## image.\<imgtype\>

The image. \<imgtype\> is just the file extension. It must match the one specified in info.txt or it won't work.

## info.txt

This file is inside of every image entry, and contains important metadata, namely the imgtype, alt text and any other idols that are in the image. All but imgtype may be omitted, but I recommend you just leave them blank.

### example layout

```
imgtype=png
alt=Haruka Amami and Chihaya Kisaragi
otheridols=chihaya
```
