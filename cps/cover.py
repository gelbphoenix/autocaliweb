# -*- coding: utf-8 -*-

#   This file is part of the Calibre-Web (https://github.com/janeczku/calibre-web)
#     Copyright (C) 2022 OzzieIsaacs
#
#   This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see <http://www.gnu.org/licenses/>.

from PIL import Image, ImageDraw, ImageFont
import os
import io

try:
    from wand.image import Image as WandImage
    use_IM = True
except (ImportError, RuntimeError) as e:
    use_IM = False


NO_JPEG_EXTENSIONS = ['.png', '.webp', '.bmp']
COVER_EXTENSIONS = ['.png', '.webp', '.bmp', '.jpg', '.jpeg']


def cover_processing(tmp_file_path, img, extension):
    # tmp_cover_name = os.path.join(os.path.dirname(tmp_file_name), 'cover.jpg')
    tmp_cover_name = tmp_file_path + '.jpg'
    if extension in NO_JPEG_EXTENSIONS:
        if use_IM:
            with WandImage(blob=img) as imgc:
                imgc.format = 'jpeg'
                imgc.transform_colorspace('srgb')
                imgc.save(filename=tmp_cover_name)
                return tmp_cover_name
        else:
            return None
    if img:
        with open(tmp_cover_name, 'wb') as f:
            f.write(img)
        return tmp_cover_name
    else:
        return None

class CoverGenerator:
    def __init__(self, width=1650, height=2200):
        """Initialize the CoverGenerator with specified dimensions."""
        self.width = width
        self.height = height
    
    def generate(self, title, author):
        """Generate a simple cover image with title and author text."""
        # Create a blank image with white background
        image = Image.new('RGB', (self.width, self.height), 'white')
        draw = ImageDraw.Draw(image)

        # Load a standard font
        # TODO: Make font path configurable
        try:
            title_font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 94)
            author_font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 72)
        except OSError:
            title_font = ImageFont.load_default()
            author_font = ImageFont.load_default()

        # center and draw the title
        title_bbox = draw.textbbox((0, 0), title, font=title_font)
        title_width = title_bbox[2] - title_bbox[0]
        title_x = (self.width - title_width) / 2
        draw.text((title_x, self.height / 3), title, fill='black', font=title_font)

        # center and draw the author
        author_bbox = draw.textbbox((0, 0), author, font=author_font)
        author_width = author_bbox[2] - author_bbox[0]
        author_x = (self.width - author_width) / 2
        draw.text((author_x, self.height / 2), author, fill='black', font=author_font)

        # Convert the image to bytes-stream in JPEG format
        img_byte_arr = io.BytesIO()
        image.save(img_byte_arr, format='JPEG')
        img_byte_arr.seek(0)

        return img_byte_arr