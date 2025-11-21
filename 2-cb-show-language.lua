local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Math = require("optmath")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local Screen = Device.screen
local T = require("ffi/util").template
local getMenuText = require("ui/widget/menu").getMenuText

local corner_mark_size = -1
local corner_mark

local scale_by_size = Screen:scaleBySize(1000000) * (1/1000000)



local userpatch = require("userpatch")

local function patchCoverBrowserShowLanguage(plugin)
        local ListMenu = require("listmenu")
        local ListMenuItem = userpatch.getUpValue(ListMenu._updateItemsBuildUI, "ListMenuItem")

        local BookInfoManager = require("bookinfomanager")

        local origListMenuItemUpdate = ListMenuItem.update


        function ListMenuItem:update()
            -- We will be a distinctive widget whether we are a directory,
            -- a known file with image / without image, or a not yet known file
            local widget

            -- we'll add a VerticalSpan of same size as underline container for balance
            local dimen = Geom:new{
                w = self.width,
                h = self.height - 2 * self.underline_h
            }

            local function _fontSize(nominal, max)
                -- The nominal font size is based on 64px ListMenuItem height.
                -- Keep ratio of font size to item height
                local font_size = math.floor(nominal * dimen.h * (1/64) / scale_by_size)
                -- But limit it to the provided max, to avoid huge font size when
                -- only 4-6 items per page
                if max and font_size >= max then
                    return max
                end
                return font_size
            end
            -- Will speed up a bit if we don't do all font sizes when
            -- looking for one that make text fit
            local fontsize_dec_step = math.ceil(_fontSize(100) * (1/100))

            -- We'll draw a border around cover images, it may not be
            -- needed with some covers, but it's nicer when cover is
            -- a pure white background (like rendered text page)
            local border_size = Size.border.thin
            local max_img_w = dimen.h - 2*border_size -- width = height, squared
            local max_img_h = dimen.h - 2*border_size
            local cover_specs = {
                max_cover_w = max_img_w,
                max_cover_h = max_img_h,
            }
            -- Make it available to our menu, for batch extraction
            -- to know what size is needed for current view
            if self.do_cover_image then
                self.menu.cover_specs = cover_specs
            else
                self.menu.cover_specs = false
            end

            self.is_directory = not (self.entry.is_file or self.entry.file)
            if self.is_directory then
                -- nb items on the right, directory name on the left
                local wright = TextWidget:new{
                    text = self.mandatory or "",
                    face = Font:getFace("infont", _fontSize(14, 18)),
                }
                local pad_width = Screen:scaleBySize(10) -- on the left, in between, and on the right
                local wleft_width = dimen.w - wright:getWidth() - 3*pad_width
                local wleft = TextBoxWidget:new{
                    text = BD.directory(self.text),
                    face = Font:getFace("cfont", _fontSize(20, 24)),
                    width = wleft_width,
                    alignment = "left",
                    bold = true,
                    height = dimen.h,
                    height_adjust = true,
                    height_overflow_show_ellipsis = true,
                }
                widget = OverlapGroup:new{
                    dimen = dimen:copy(),
                    LeftContainer:new{
                        dimen = dimen:copy(),
                        HorizontalGroup:new{
                            HorizontalSpan:new{ width = pad_width },
                            wleft,
                        }
                    },
                    RightContainer:new{
                        dimen = dimen:copy(),
                        HorizontalGroup:new{
                            wright,
                            HorizontalSpan:new{ width = pad_width },
                        },
                    },
                }
            else -- file
                self.file_deleted = self.entry.dim -- entry with deleted file from History or selected file from FM
                local fgcolor = self.file_deleted and Blitbuffer.COLOR_DARK_GRAY or nil

                local bookinfo = BookInfoManager:getBookInfo(self.filepath, self.do_cover_image)

                if bookinfo and self.do_cover_image and not bookinfo.ignore_cover and not self.file_deleted then
                    if bookinfo.cover_fetched then
                        if bookinfo.has_cover and not self.menu.no_refresh_covers then
                            if BookInfoManager.isCachedCoverInvalid(bookinfo, cover_specs) then
                                -- there is a thumbnail, but it's smaller than is needed for new grid dimensions,
                                -- and it would be ugly if scaled up to the required size:
                                -- do as if not found to force a new extraction with our size
                                if bookinfo.cover_bb then
                                    bookinfo.cover_bb:free()
                                end
                                bookinfo = nil
                            end
                        end
                        -- if not has_cover, book has no cover, no need to try again
                    else
                        -- cover was not fetched previously, do as if not found
                        -- to force a new extraction
                        bookinfo = nil
                    end
                end

                local book_info = self.menu.getBookInfo(self.filepath)
                self.been_opened = book_info.been_opened
                if bookinfo then -- This book is known
                    self.bookinfo_found = true
                    local cover_bb_used = false

                    -- Build the left widget : image if wanted
                    local wleft = nil
                    local wleft_width = 0 -- if not do_cover_image
                    local wleft_height
                    if self.do_cover_image then
                        wleft_height = dimen.h
                        wleft_width = wleft_height -- make it squared
                        if bookinfo.has_cover and not bookinfo.ignore_cover then
                            cover_bb_used = true
                            -- Let ImageWidget do the scaling and give us the final size
                            local _, _, scale_factor = BookInfoManager.getCachedCoverSize(bookinfo.cover_w, bookinfo.cover_h, max_img_w, max_img_h)
                            local wimage = ImageWidget:new{
                                image = bookinfo.cover_bb,
                                scale_factor = scale_factor,
                            }
                            wimage:_render()
                            local image_size = wimage:getSize() -- get final widget size
                            wleft = CenterContainer:new{
                                dimen = Geom:new{ w = wleft_width, h = wleft_height },
                                FrameContainer:new{
                                    width = image_size.w + 2*border_size,
                                    height = image_size.h + 2*border_size,
                                    margin = 0,
                                    padding = 0,
                                    bordersize = border_size,
                                    dim = self.file_deleted,
                                    wimage,
                                }
                            }
                            -- Let menu know it has some item with images
                            self.menu._has_cover_images = true
                            self._has_cover_image = true
                        else
                            local fake_cover_w = max_img_w * 0.6
                            local fake_cover_h = max_img_h
                            wleft = CenterContainer:new{
                                dimen = Geom:new{ w = wleft_width, h = wleft_height },
                                FrameContainer:new{
                                    width = fake_cover_w + 2*border_size,
                                    height = fake_cover_h + 2*border_size,
                                    margin = 0,
                                    padding = 0,
                                    bordersize = border_size,
                                    dim = self.file_deleted,
                                    CenterContainer:new{
                                        dimen = Geom:new{ w = fake_cover_w, h = fake_cover_h },
                                        TextWidget:new{
                                            text = "⛶", -- U+26F6 Square four corners
                                            face = Font:getFace("cfont",  _fontSize(20)),
                                        },
                                    },
                                },
                            }
                        end
                    end
                    -- In case we got a blitbuffer and didn't use it (ignore_cover), free it
                    if bookinfo.cover_bb and not cover_bb_used then
                        bookinfo.cover_bb:free()
                    end
                    -- So we can draw an indicator if this book has a description
                    if bookinfo.description then
                        self.has_description = true
                    end

                    -- Gather some info, mostly for right widget:
                    --   file size (self.mandatory) (not available with History)
                    --   file type
                    --   pages read / nb of pages (not available for crengine doc not opened)
                    -- Current page / pages are available or more accurate in .sdr/metadata.lua
                    local pages = book_info.pages or bookinfo.pages -- default to those in bookinfo db
                    local percent_finished = book_info.percent_finished
                    local status = book_info.status
                    -- right widget, first line
                    local directory, filename = util.splitFilePathName(self.filepath) -- luacheck: no unused
                    local filename_without_suffix, filetype = filemanagerutil.splitFileNameType(filename)
                    local fileinfo_str
                    if bookinfo._no_provider then
                        -- for unsupported files: don't show extension on the right,
                        -- keep it in filename
                        filename_without_suffix = filename
                        fileinfo_str = self.mandatory
                    else
                        local mark = book_info.has_annotations and "\u{2592}  " or "" -- "medium shade"
                        fileinfo_str = mark .. BD.wrap(filetype) .. (bookinfo.language and ("  " .. bookinfo.language) or "") .. "  " .. BD.wrap(self.mandatory) -- actual patch
                    end
                    -- right widget, second line
                    local pages_str = ""
                    if status == "complete" or status == "abandoned" then
                        -- Display these instead of the read %
                        if pages then
                            if status == "complete" then
                                pages_str = T(N_("Finished – 1 page", "Finished – %1 pages", pages), pages)
                            else
                                pages_str = T(N_("On hold – 1 page", "On hold – %1 pages", pages), pages)
                            end
                        else
                            pages_str = status == "complete" and _("Finished") or _("On hold")
                        end
                    elseif percent_finished then
                        if pages then
                            if BookInfoManager:getSetting("show_pages_read_as_progress") then
                                pages_str = T(_("Page %1 of %2"), Math.round(percent_finished*pages), pages)
                            else
                                pages_str = T(N_("%1 % of 1 page", "%1 % of %2 pages", pages), math.floor(100*percent_finished), pages)
                            end
                            if BookInfoManager:getSetting("show_pages_left_in_progress") then
                                pages_str = T(_("%1, %2 to read"), pages_str, Math.round(pages-percent_finished*pages), pages)
                            end
                        else
                            pages_str = string.format("%d %%", 100*percent_finished)
                        end
                    else
                        if pages then
                            pages_str = T(N_("1 page", "%1 pages", pages), pages)
                        end
                    end

                    -- Build the right widget

                    local fontsize_info = _fontSize(14, 18)

                    local wright_items = {align = "right"}
                    local wright_right_padding = 0
                    local wright_width = 0
                    local wright

                    if not BookInfoManager:getSetting("hide_file_info") then
                        local wfileinfo = TextWidget:new{
                            text = fileinfo_str,
                            face = Font:getFace("cfont", fontsize_info),
                            fgcolor = fgcolor,
                        }
                        table.insert(wright_items, wfileinfo)
                    end

                    if not BookInfoManager:getSetting("hide_page_info") then
                        local wpageinfo = TextWidget:new{
                            text = pages_str,
                            face = Font:getFace("cfont", fontsize_info),
                            fgcolor = fgcolor,
                        }
                        table.insert(wright_items, wpageinfo)
                    end

                    if #wright_items > 0 then
                        for i, w in ipairs(wright_items) do
                            wright_width = math.max(wright_width, w:getSize().w)
                        end
                        wright = CenterContainer:new{
                            dimen = Geom:new{ w = wright_width, h = dimen.h },
                            VerticalGroup:new(wright_items),
                        }
                        wright_right_padding = Screen:scaleBySize(10)
                    end

                    -- Create or replace corner_mark if needed
                    local mark_size = math.floor(dimen.h * (1/6))
                    -- Just fits under the page info text, which in turn adapts to the ListMenuItem height.
                    if mark_size ~= corner_mark_size then
                        corner_mark_size = mark_size
                        if corner_mark then
                            corner_mark:free()
                        end
                        corner_mark = IconWidget:new{
                            icon = "dogear.opaque",
                            rotation_angle = BD.mirroredUILayout() and 180 or 270,
                            width = corner_mark_size,
                            height = corner_mark_size,
                        }
                    end

                    -- Build the middle main widget, in the space available
                    local wmain_left_padding = Screen:scaleBySize(10)
                    if self.do_cover_image then
                        -- we need less padding, as cover image, most often in
                        -- portrait mode, will provide some padding
                        wmain_left_padding = Screen:scaleBySize(5)
                    end
                    local wmain_right_padding = Screen:scaleBySize(10) -- used only for next calculation
                    local wmain_width = dimen.w - wleft_width - wmain_left_padding - wmain_right_padding - wright_width - wright_right_padding

                    local fontname_title = "cfont"
                    local fontname_authors = "cfont"
                    local fontsize_title = _fontSize(20, 24)
                    local fontsize_authors = _fontSize(18, 22)
                    local wtitle, wauthors
                    local title, authors, reduce_font_size
                    local fixed_font_size = BookInfoManager:getSetting("fixed_item_font_size")
                    local series_mode = BookInfoManager:getSetting("series_mode")

                    -- whether to use or not title and authors
                    -- (We wrap each metadata text with BD.auto() to get for each of them
                    -- the text direction from the first strong character - which should
                    -- individually be the best thing, and additionally prevent shuffling
                    -- if concatenated.)
                    if self.do_filename_only or bookinfo.ignore_meta then
                        title = filename_without_suffix -- made out above
                        authors = nil
                    else
                        title = bookinfo.title or filename_without_suffix
                        authors = bookinfo.authors
                        -- If multiple authors (crengine separates them with \n), we
                        -- can display them on multiple lines, but limit to 2, and
                        -- append "et al." to the 2nd if there are more
                        if authors and authors:find("\n") then
                            authors = util.splitToArray(authors, "\n")
                            for i=1, #authors do
                                authors[i] = BD.auto(authors[i])
                            end
                            if #authors > 1 and bookinfo.series and series_mode == "series_in_separate_line" then
                                authors = { T(_("%1 et al."), authors[1]) }
                            elseif #authors > 2 then
                                authors = { authors[1], T(_("%1 et al."), authors[2]) }
                            end
                            authors = table.concat(authors, "\n")
                            -- as we'll fit 3 lines instead of 2, we can avoid some loops by starting from a lower font size
                            reduce_font_size = true
                        elseif authors then
                            authors = BD.auto(authors)
                        end
                    end
                    title = BD.auto(title)
                    -- add Series metadata if requested
                    if series_mode and bookinfo.series then
                        local series = bookinfo.series_index and bookinfo.series .. " #" .. bookinfo.series_index
                            or bookinfo.series
                        series = BD.auto(series)
                        if series_mode == "append_series_to_title" then
                            title = title .. " - " .. series
                        elseif series_mode == "append_series_to_authors" then
                            authors = authors and authors .. " - " .. series or series
                        else -- "series_in_separate_line"
                            if authors then
                                authors = series .. "\n" .. authors
                                -- as we'll fit 3 lines instead of 2, we can avoid some loops by starting from a lower font size
                                reduce_font_size = true
                            else
                                authors = series
                            end
                        end
                    end
                    if reduce_font_size and not fixed_font_size then
                        fontsize_title = _fontSize(17, 21)
                        fontsize_authors = _fontSize(15, 19)
                    end
                    if bookinfo.unsupported then
                        -- Let's show this fact in place of the anyway empty authors slot
                        authors = T(_("(no book information: %1)"), _(bookinfo.unsupported))
                    end
                    -- Build title and authors texts with decreasing font size
                    -- till it fits in the space available
                    local build_title = function(height)
                        if wtitle then
                            wtitle:free(true)
                            wtitle = nil
                        end
                        -- BookInfoManager:extractBookInfo() made sure
                        -- to save as nil (NULL) metadata that were an empty string
                        -- We provide the book language to get a chance to render title
                        -- and authors with alternate glyphs for that language.
                        wtitle = TextBoxWidget:new{
                            text = title,
                            lang = bookinfo.language,
                            face = Font:getFace(fontname_title, fontsize_title),
                            width = wmain_width,
                            height = height,
                            height_adjust = true,
                            height_overflow_show_ellipsis = true,
                            alignment = "left",
                            bold = true,
                            fgcolor = fgcolor,
                        }
                    end
                    local build_authors = function(height)
                        if wauthors then
                            wauthors:free(true)
                            wauthors = nil
                        end
                        wauthors = TextBoxWidget:new{
                            text = authors,
                            lang = bookinfo.language,
                            face = Font:getFace(fontname_authors, fontsize_authors),
                            width = wmain_width,
                            height = height,
                            height_adjust = true,
                            height_overflow_show_ellipsis = true,
                            alignment = "left",
                            fgcolor = fgcolor,
                        }
                    end
                    while true do
                        build_title()
                        local height = wtitle:getSize().h
                        if authors then
                            build_authors()
                            height = height + wauthors:getSize().h
                        end
                        if height <= dimen.h then
                            -- We fit!
                            break
                        end
                        -- Don't go too low, and get out of this loop.
                        if fixed_font_size or fontsize_title <= 12 or fontsize_authors <= 10 then
                            local title_height = wtitle:getSize().h
                            local title_line_height = wtitle:getLineHeight()
                            local title_min_height = 2 * title_line_height -- unscaled_size_check: ignore
                            local authors_height = authors and wauthors:getSize().h or 0
                            local authors_line_height = authors and wauthors:getLineHeight() or 0
                            local authors_min_height = 2 * authors_line_height -- unscaled_size_check: ignore
                            -- Chop lines, starting with authors, until
                            -- both labels fit in the allocated space.
                            while title_height + authors_height > dimen.h do
                                if authors_height > authors_min_height then
                                    authors_height = authors_height - authors_line_height
                                elseif title_height > title_min_height then
                                    title_height = title_height - title_line_height
                                else
                                    break
                                end
                            end
                            if title_height < wtitle:getSize().h then
                                build_title(title_height)
                            end
                            if authors and authors_height < wauthors:getSize().h then
                                build_authors(authors_height)
                            end
                            break
                        end
                        -- If we don't fit, decrease both font sizes
                        fontsize_title = fontsize_title - fontsize_dec_step
                        fontsize_authors = fontsize_authors - fontsize_dec_step
                        logger.dbg(title, "recalculate title/author with", fontsize_title)
                    end

                    local wmain = LeftContainer:new{
                        dimen = dimen:copy(),
                        VerticalGroup:new{
                            wtitle,
                            wauthors,
                        }
                    }

                    -- Build the final widget
                    widget = OverlapGroup:new{
                        dimen = dimen:copy(),
                    }
                    if self.do_cover_image then
                        -- add left widget
                        if wleft then
                            -- no need for left padding, as cover image, most often in
                            -- portrait mode, will have some padding - the rare landscape
                            -- mode cover image will be stuck to screen side thus
                            table.insert(widget, wleft)
                        end
                        -- pad main widget on the left with size of left widget
                        wmain = HorizontalGroup:new{
                                HorizontalSpan:new{ width = wleft_width },
                                HorizontalSpan:new{ width = wmain_left_padding },
                                wmain
                        }
                    else
                        -- pad main widget on the left
                        wmain = HorizontalGroup:new{
                                HorizontalSpan:new{ width = wmain_left_padding },
                                wmain
                        }
                    end
                    -- add padded main widget
                    table.insert(widget, LeftContainer:new{
                            dimen = dimen:copy(),
                            wmain
                        })
                    -- add right widget
                    if wright then
                        table.insert(widget, RightContainer:new{
                            dimen = dimen:copy(),
                            HorizontalGroup:new{
                                wright,
                                HorizontalSpan:new{ width = wright_right_padding },
                            },
                        })
                    end

                else -- bookinfo not found
                    if self.init_done then
                        -- Non-initial update(), but our widget is still not found:
                        -- it does not need to change, so avoid remaking the same widget
                        return
                    end
                    -- If we're in no image mode, don't save images in DB : people
                    -- who don't care about images will have a smaller DB, but
                    -- a new extraction will have to be made when one switch to image mode
                    if self.do_cover_image then
                        -- Not in db, we're going to fetch some cover
                        self.cover_specs = cover_specs
                    end
                    -- No right widget by default, except in History
                    local wright
                    local wright_width = 0
                    local wright_right_padding = 0
                    if self.mandatory then
                        -- Currently only provided by History, giving the last time read.
                        -- If we have it, we need to build a more complex widget with
                        -- this date on the right
                        local fileinfo_str = self.mandatory
                        local fontsize_info = _fontSize(14, 18)
                        local wfileinfo = TextWidget:new{
                            text = fileinfo_str,
                            face = Font:getFace("cfont", fontsize_info),
                            fgcolor = fgcolor,
                        }
                        local wpageinfo = TextWidget:new{ -- Empty but needed for similar positioning
                            text = "",
                            face = Font:getFace("cfont", fontsize_info),
                        }
                        wright_width = wfileinfo:getSize().w
                        wright = CenterContainer:new{
                            dimen = Geom:new{ w = wright_width, h = dimen.h },
                            VerticalGroup:new{
                                align = "right",
                                VerticalSpan:new{ width = Screen:scaleBySize(2) },
                                wfileinfo,
                                wpageinfo,
                            }
                        }
                        wright_right_padding = Screen:scaleBySize(10)
                    end
                    -- A real simple widget, nothing fancy
                    local hint = "…" -- display hint it's being loaded
                    if self.file_deleted then -- unless file was deleted (can happen with History)
                        hint = " " .. _("(deleted)")
                    end
                    local text = BD.filename(self.text)
                    local text_widget
                    local fontsize_no_bookinfo = _fontSize(18, 22)
                    repeat
                        if text_widget then
                            text_widget:free(true)
                        end
                        text_widget = TextBoxWidget:new{
                            text = text .. hint,
                            face = Font:getFace("cfont", fontsize_no_bookinfo),
                            width = dimen.w - 2 * Screen:scaleBySize(10) - wright_width - wright_right_padding,
                            alignment = "left",
                            fgcolor = fgcolor,
                        }
                        -- reduce font size for next loop, in case text widget is too large to fit into ListMenuItem
                        fontsize_no_bookinfo = fontsize_no_bookinfo - fontsize_dec_step
                    until text_widget:getSize().h <= dimen.h
                    widget = LeftContainer:new{
                        dimen = dimen:copy(),
                        HorizontalGroup:new{
                            HorizontalSpan:new{ width = Screen:scaleBySize(10) },
                            text_widget
                        },
                    }
                    if wright then -- last read date, in History, even for deleted files
                        widget = OverlapGroup:new{
                            dimen = dimen:copy(),
                            widget,
                            RightContainer:new{
                                dimen = dimen:copy(),
                                HorizontalGroup:new{
                                    wright,
                                    HorizontalSpan:new{ width = wright_right_padding },
                                },
                            },
                        }
                    end
                end
            end

            -- Fill container with our widget
            if self._underline_container[1] then
                -- There is a previous one, that we need to free()
                local previous_widget = self._underline_container[1]
                previous_widget:free()
            end
            -- Add some pad at top to balance with hidden underline line at bottom
            self._underline_container[1] = VerticalGroup:new{
                VerticalSpan:new{ width = self.underline_h },
                widget
            }
        end

end

userpatch.registerPatchPluginFunc("coverbrowser", patchCoverBrowserShowLanguage)
