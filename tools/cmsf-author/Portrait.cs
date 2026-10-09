// Portrait from an ordinary image: an author hands over a PNG, not a cooked texture.
//
// The first outside author to use CMSF had a working model and no cooked portrait. A portrait
// is mandatory (an unclaimed icon gets the tile pruned), so the only way forward was a second
// trip through Unreal for one image. This removes that trip.
//
// Every character-select portrait in the game is the same kind of texture: uncompressed
// PF_B8G8R8A8, one mip, NeverStream. The base characters' are 550x950, the DLC skins' 551x942.
// The pixels sit inline in the .uexp as one W*H*4 payload, directly followed by the mip's
// SizeX, SizeY, SizeZ. The payload's size lives in the .uasset's data-resource map, not in the
// .uexp, so a replacement of exactly the same dimensions is a byte swap: nothing else in the
// package moves. So the image is fitted to the character's own base portrait and written over
// a copy of it, and from there it is cloned like any other icon.
//
// Linked into tools/mshgen too, so the Python reference bakes with the same code.
using System.Text;
using StbImageSharp;

static class Portrait
{
    public const string MenuDir = "/Game/UI/Textures/MainMenu/Menu";

    // CMSF character -> the suffix of its base portrait, T_Menu_PickCharacter_Portrait_<x>.
    static readonly Dictionary<string, string> Base = new(StringComparer.OrdinalIgnoreCase)
    {
        ["BagMan"] = "BagMan", ["Girl"] = "ScavGirl", ["Gunhead"] = "Gunhead",
        ["MaskMan"] = "MaskMan", ["OldMan"] = "OldMan", ["Shaman"] = "Shaman",
    };

    static readonly string[] ImageExts = { ".png", ".jpg", ".jpeg", ".bmp", ".tga" };

    public static bool IsImage(string value) =>
        ImageExts.Contains(Path.GetExtension(value), StringComparer.OrdinalIgnoreCase);

    /// <summary>The /Game/ path (with its .Object, as skin.json writes one) of the template a
    /// character's image portrait is baked into.</summary>
    public static string TemplateFor(string character) =>
        Base.TryGetValue(character, out var s)
            ? $"{MenuDir}/T_Menu_PickCharacter_Portrait_{s}.T_Menu_PickCharacter_Portrait_{s}"
            : throw new BuildError($"no portrait template known for character '{character}'");

    /// <summary>
    /// Write <paramref name="image"/> over the pixels of the cooked texture at
    /// <paramref name="tplUasset"/> (a copy the caller owns; its .uexp is rewritten in place).
    /// Returns what was done to the image, for the console.
    /// </summary>
    public static string Bake(string image, string tplUasset)
    {
        var uexp = Path.ChangeExtension(tplUasset, ".uexp");
        var b = File.ReadAllBytes(uexp);
        var (w, h, start) = Layout(b, Path.GetFileName(uexp));

        ImageResult img;
        using (var fs = File.OpenRead(image))
        {
            try { img = ImageResult.FromStream(fs, ColorComponents.RedGreenBlueAlpha); }
            catch (Exception e) { throw new BuildError($"icon: could not read {Path.GetFileName(image)} as an image ({e.Message})"); }
        }

        var rgb = OverWhite(img.Data, img.Width * img.Height);
        var fitted = Cover(rgb, img.Width, img.Height, w, h, out var note);

        // RGB -> BGRA, opaque. The game's portraits are opaque over white, so we match them.
        for (int i = 0, o = start; i < w * h; i++, o += 4)
        {
            b[o] = fitted[i * 3 + 2];
            b[o + 1] = fitted[i * 3 + 1];
            b[o + 2] = fitted[i * 3];
            b[o + 3] = 255;
        }
        File.WriteAllBytes(uexp, b);
        return $"{img.Width}x{img.Height} -> {w}x{h}{note}";
    }

    /// <summary>
    /// Find the single inline mip, and refuse anything that isn't the layout described above.
    /// Both ends are checked: the header (dimensions, format, one mip) and the trailer that
    /// must follow exactly W*H*4 bytes later. A template that fails either check is one the
    /// game changed, and swapping bytes into it blind would corrupt it.
    /// </summary>
    static (int W, int H, int Start) Layout(byte[] b, string what)
    {
        var fmt = Encoding.ASCII.GetBytes("PF_B8G8R8A8\0");
        int p = IndexOf(b, fmt);
        if (p < 16 || BitConverter.ToInt32(b, p - 4) != fmt.Length)
            throw new BuildError($"{what}: not an uncompressed B8G8R8A8 texture; the portrait template has changed");
        int w = BitConverter.ToInt32(b, p - 16), h = BitConverter.ToInt32(b, p - 12);
        int afterFmt = p + fmt.Length;
        int numMips = BitConverter.ToInt32(b, afterFmt + 4);
        int start = afterFmt + 12;   // FirstMip, NumMips, the mip's data-resource index
        long n = (long)w * h * 4;
        if (w <= 0 || h <= 0 || w > 8192 || h > 8192 || numMips != 1 || start + n + 12 > b.Length ||
            BitConverter.ToInt32(b, (int)(start + n)) != w ||
            BitConverter.ToInt32(b, (int)(start + n + 4)) != h ||
            BitConverter.ToInt32(b, (int)(start + n + 8)) != 1)
            throw new BuildError($"{what}: unexpected texture layout ({w}x{h}, {numMips} mip(s)); " +
                                 "the portrait template has changed, so an image portrait can't be baked into it");
        return (w, h, start);
    }

    static int IndexOf(byte[] hay, byte[] needle)
    {
        for (int i = 0; i + needle.Length <= hay.Length; i++)
        {
            int j = 0;
            while (j < needle.Length && hay[i + j] == needle[j]) j++;
            if (j == needle.Length) return i;
        }
        return -1;
    }

    /// <summary>RGBA -> RGB composited over white, the background every game portrait has.</summary>
    static byte[] OverWhite(byte[] rgba, int count)
    {
        var o = new byte[count * 3];
        for (int i = 0; i < count; i++)
        {
            int a = rgba[i * 4 + 3];
            for (int c = 0; c < 3; c++)
                o[i * 3 + c] = (byte)((rgba[i * 4 + c] * a + 255 * (255 - a) + 127) / 255);
        }
        return o;
    }

    /// <summary>
    /// Scale to cover W x H and centre-crop, like a background image. Separable tent filter,
    /// widened when shrinking so it averages rather than skips. Plain doubles summed in a fixed
    /// order, so the exe and mshgen bake identical bytes.
    /// </summary>
    static byte[] Cover(byte[] src, int sw, int sh, int w, int h, out string note)
    {
        double scale = Math.Max((double)w / sw, (double)h / sh);
        double ox = (sw * scale - w) / 2, oy = (sh * scale - h) / 2;
        note = "";
        if (Math.Abs((double)sw / sh - (double)w / h) > 0.01)
            note += ox > 0.5 ? $", {ox * 200 / (sw * scale):F0}% of the width cropped"
                             : $", {oy * 200 / (sh * scale):F0}% of the height cropped";
        if (scale > 1.0001) note += $", upscaled x{scale:F2} (a {w}x{h} source looks sharper)";

        var mid = new double[w * sh * 3];
        Pass(src, sw, sh, mid, w, scale, ox, horizontal: true);
        var dst = new double[w * h * 3];
        Pass(mid, w, sh, dst, h, scale, oy, horizontal: false);

        var o = new byte[w * h * 3];
        for (int i = 0; i < o.Length; i++) o[i] = (byte)Math.Clamp((int)Math.Round(dst[i]), 0, 255);
        return o;
    }

    static void Pass(IList<byte> src, int sw, int sh, double[] dst, int outLen, double scale, double off, bool horizontal)
        => Pass(src.Select(x => (double)x).ToArray(), sw, sh, dst, outLen, scale, off, horizontal);

    static void Pass(double[] src, int sw, int sh, double[] dst, int outLen, double scale, double off, bool horizontal)
    {
        int inLen = horizontal ? sw : sh, lines = horizontal ? sh : sw;
        int outW = horizontal ? outLen : sw;
        double support = Math.Max(1.0, 1.0 / scale);
        for (int o = 0; o < outLen; o++)
        {
            double centre = (o + off + 0.5) / scale - 0.5;
            int lo = (int)Math.Floor(centre - support) + 1, hi = (int)Math.Floor(centre + support);
            var taps = new List<(int I, double W)>();
            double sum = 0;
            for (int i = lo; i <= hi; i++)
            {
                double wt = 1.0 - Math.Abs(i - centre) / support;
                if (wt <= 0) continue;
                taps.Add((Math.Clamp(i, 0, inLen - 1), wt));
                sum += wt;
            }
            for (int l = 0; l < lines; l++)
                for (int c = 0; c < 3; c++)
                {
                    double acc = 0;
                    foreach (var (i, wt) in taps)
                        acc += src[(horizontal ? l * sw + i : i * sw + l) * 3 + c] * wt;
                    dst[(horizontal ? l * outW + o : o * outW + l) * 3 + c] = acc / sum;
                }
        }
    }
}
