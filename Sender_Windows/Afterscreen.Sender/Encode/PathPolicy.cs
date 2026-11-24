using Afterscreen.Protocol;

namespace Afterscreen.Sender.Encode;

/// <summary>Mac <c>PathPolicy</c> helpers used mid-session (handover relink). Full choose() lives in <see cref="EncodeServices"/>.</summary>
public static class PathPolicy
{
    /// <summary>Lossless tiles need about this many bits per pixel per frame (Mac 2.8).</summary>
    public const double TileBitsPerPixel = 2.8;

    public static double TileCapacityGbps(PixelSize stream, double fps) =>
        (double)stream.Width * stream.Height * fps * TileBitsPerPixel / 1e9;

    /// <summary>
    /// A session moving to another link: size and rate stay; path, video layer bitrate and link follow capacity.
    /// Does not re-measure encoder capacity (keeps current video pixels).
    /// </summary>
    public static StreamConfig Relink(StreamConfig current, LinkKind link, double? capacityGbps, Welcome welcome)
    {
        var fps = current.FrameRate > 0 ? current.FrameRate : 60;
        var stream = current.StreamPixels;
        var wired = link is LinkKind.thunderbolt or LinkKind.usb or LinkKind.ethernet or LinkKind.loopback;
        if (wired && (capacityGbps ?? 0) >= TileCapacityGbps(stream, fps))
        {
            return new StreamConfig
            {
                Path = StreamPath.tile,
                StreamPixels = stream,
                Video = null,
                LinkKind = link,
                FrameRate = fps,
                Test = current.Test,
            };
        }

        if (!welcome.HevcDecode && !welcome.H264Decode)
        {
            return new StreamConfig
            {
                Path = StreamPath.tile,
                StreamPixels = stream,
                Video = null,
                LinkKind = link,
                FrameRate = fps,
                Test = current.Test,
            };
        }

        var codec = welcome.HevcDecode ? VideoCodec.hevc : VideoCodec.h264;
        var bitrate = EncodeServices.VideoBitrateMbps(capacityGbps);
        var pixels = current.Video?.Pixels ?? stream;
        var ten = codec == VideoCodec.hevc && welcome.HevcMain10Decode;
        return new StreamConfig
        {
            Path = StreamPath.hybrid,
            StreamPixels = stream,
            Video = new VideoLayer { Codec = codec, Pixels = pixels, Bitrate = bitrate, TenBit = ten },
            LinkKind = link,
            FrameRate = fps,
            Test = current.Test,
        };
    }
}
