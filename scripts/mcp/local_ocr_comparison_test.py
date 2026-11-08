"""Small correctness checks for benchmark image conversion; not OCR accuracy claims."""
import struct
import unittest
import zlib
from local_ocr_comparison import grey_png, prepared_pgm


def png(rows):
    def chunk(tag, data):
        return struct.pack('>I', len(data))+tag+data+struct.pack('>I', zlib.crc32(tag+data))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB', 3, 2, 8, 0, 0, 0, 0))+chunk(b'IDAT', zlib.compress(rows))+chunk(b'IEND', b'')


class CorpusConversionTests(unittest.TestCase):
    def test_filter_predictors_decode_the_same_pixels(self):
        # Expected rows [20, 60, 100], [40, 80, 120], encoded independently per PNG filter.
        for rows in [bytes([0,20,60,100,0,40,80,120]),
                     bytes([1,20,40,40,1,40,40,40]),
                     bytes([2,20,60,100,2,20,20,20]),
                     bytes([3,20,50,70,3,30,30,30]),
                     bytes([4,20,40,40,4,20,20,20])]:
            w,h,pixels = grey_png(png(rows))
            self.assertEqual((w,h,list(pixels)),(3,2,[20,60,100,40,80,120]))

    def test_nearest_enlargement_preserves_pixel_values(self):
        result=prepared_pgm(png(bytes([0,20,60,100,0,40,80,120])),False)
        header,payload=result.split(b'255\n',1)
        self.assertEqual(header,b'P5\n9 6\n')
        self.assertEqual(payload,(bytes([20]*3+[60]*3+[100]*3))*3+(bytes([40]*3+[80]*3+[120]*3))*3)

    def test_rejects_invalid_or_unbounded_inputs(self):
        with self.assertRaises(ValueError): grey_png(b'not PNG')
        with self.assertRaises(ValueError): grey_png(png(bytes([5,0,0,0,0,0,0,0])))
        with self.assertRaises(ValueError): grey_png(png(bytes([0,1])))


if __name__=='__main__': unittest.main()
